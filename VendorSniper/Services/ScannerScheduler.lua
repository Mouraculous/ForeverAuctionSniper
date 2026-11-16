--[[
ScannerScheduler: coordinates asynchronous work without blocking the UI and
without breaking Auction House query limits.

1. Chunked jobs: process a large list a few items per frame. Only one job
   runs at a time (prevents duplicate scans). Jobs can be cancelled.
2. Listing lookups: a queue of SendSearchQuery targets, sent strictly one
   at a time.
   * The next lookup is sent only after the previous one's results arrived
     (OnSearchResults). A watchdog (responseTimeout) stops a lost response
     from stalling the queue.
   * Sending waits for IsThrottleReady() / OnThrottleReady() (the client's
     AUCTION_HOUSE_THROTTLED_* system).
   * A rolling 60-second budget (maxPerMinute) is enforced on top, well
     below the documented 100/min.
   * A dropped message is re-queued at most `maxRetries` times.

Dependencies (injected):
  now() -> seconds, after(seconds, fn), defer(fn),
  isThrottleReady() -> bool, sendSearch(target) -> bool,
  callbacks (optional) fires LOOKUP_STATE_CHANGED, LOOKUP_SENT, LOOKUP_DONE.

A lookup target is { id = string, matchKeys = { groupKey, ... }, ... }.
]]
local _, ns = ...

local ScannerScheduler = {}
ScannerScheduler.__index = ScannerScheduler
ns.ScannerScheduler = ScannerScheduler

ScannerScheduler.STATE_IDLE = "idle"
ScannerScheduler.STATE_WAITING_RESPONSE = "waitingResponse"
ScannerScheduler.STATE_WAITING_THROTTLE = "waitingThrottle"
ScannerScheduler.STATE_WAITING_RATE_LIMIT = "waitingRateLimit"

ScannerScheduler.RESULT_OK = "ok"
ScannerScheduler.RESULT_TIMEOUT = "timeout"
ScannerScheduler.RESULT_DROPPED = "dropped"
ScannerScheduler.RESULT_SEND_FAILED = "sendFailed"

local WINDOW_SECONDS = 60

-- RateLimiter --------------------------------------------------------------

local RateLimiter = {}
RateLimiter.__index = RateLimiter
ScannerScheduler.RateLimiter = RateLimiter

function RateLimiter.New(maxPerWindow, windowSeconds)
	return setmetatable({ max = maxPerWindow, window = windowSeconds or WINDOW_SECONDS, stamps = {} }, RateLimiter)
end

function RateLimiter:Prune(now)
	local stamps = self.stamps
	local cutoff = now - self.window
	local keep = 1
	while stamps[keep] and stamps[keep] <= cutoff do
		keep = keep + 1
	end
	if keep > 1 then
		local pruned = {}
		for i = keep, #stamps do
			pruned[#pruned + 1] = stamps[i]
		end
		self.stamps = pruned
	end
end

-- Returns true (and records the call), or false plus the seconds to wait.
function RateLimiter:TryAcquire(now)
	self:Prune(now)
	if #self.stamps < self.max then
		self.stamps[#self.stamps + 1] = now
		return true, 0
	end
	return false, (self.stamps[1] + self.window) - now
end

function RateLimiter:Used(now)
	self:Prune(now)
	return #self.stamps
end

-- Scheduler ----------------------------------------------------------------

function ScannerScheduler.New(deps)
	local self = setmetatable({}, ScannerScheduler)
	self.deps = deps
	self.callbacks = deps.callbacks
	self.responseTimeout = deps.responseTimeout or 10
	self.maxRetries = deps.maxRetries or 2
	self.limiter = RateLimiter.New(deps.maxPerMinute or 30, WINDOW_SECONDS)
	self.job = nil
	self.jobGeneration = 0
	self.queue = {}
	self.inFlight = nil
	self.lookupGeneration = 0
	self.rateTimerPending = false
	self.state = ScannerScheduler.STATE_IDLE
	self.completed = 0
	self.batchTotal = 0
	return self
end

function ScannerScheduler:Fire(event, ...)
	if self.callbacks then
		self.callbacks:Fire(event, ...)
	end
end

-- Chunked jobs -------------------------------------------------------------

function ScannerScheduler:IsJobRunning()
	return self.job ~= nil
end

--[[
Starts processing `items`, chunkSize per frame.
processItem(item, index) errors are caught per item and counted, so one
malformed entry can't abort the job.
onProgress(done, total), onComplete(cancelled, failures)
Returns true, or false plus "busy".
]]
function ScannerScheduler:StartJob(items, chunkSize, processItem, onProgress, onComplete)
	if self.job then
		return false, "busy"
	end
	self.jobGeneration = self.jobGeneration + 1
	local generation = self.jobGeneration
	local job = {
		items = items,
		index = 1,
		total = #items,
		chunkSize = math.max(1, chunkSize or 50),
		processItem = processItem,
		onProgress = onProgress,
		onComplete = onComplete,
		failures = 0,
	}
	self.job = job

	local function step()
		if self.job ~= job or self.jobGeneration ~= generation then
			return -- cancelled or replaced
		end
		local last = math.min(job.index + job.chunkSize - 1, job.total)
		for i = job.index, last do
			local ok = pcall(job.processItem, job.items[i], i)
			if not ok then
				job.failures = job.failures + 1
			end
		end
		job.index = last + 1
		if job.onProgress then
			job.onProgress(last, job.total)
		end
		if job.index > job.total then
			self.job = nil
			if job.onComplete then
				job.onComplete(false, job.failures)
			end
		else
			self.deps.defer(step)
		end
	end

	step()
	return true
end

function ScannerScheduler:CancelJob()
	local job = self.job
	if not job then
		return false
	end
	self.job = nil
	self.jobGeneration = self.jobGeneration + 1
	if job.onComplete then
		job.onComplete(true, job.failures)
	end
	return true
end

-- Lookups ------------------------------------------------------------------

function ScannerScheduler:SetMaxPerMinute(maxPerMinute)
	self.limiter.max = maxPerMinute
end

function ScannerScheduler:IsQueued(id)
	if self.inFlight and self.inFlight.id == id then
		return true
	end
	for i = 1, #self.queue do
		if self.queue[i].id == id then
			return true
		end
	end
	return false
end

function ScannerScheduler:SetState(state)
	if self.state ~= state then
		self.state = state
		self:Fire("LOOKUP_STATE_CHANGED", self:GetLookupStatus())
	end
end

function ScannerScheduler:GetLookupStatus()
	return {
		state = self.state,
		queued = #self.queue,
		inFlight = self.inFlight and self.inFlight.id or nil,
		completed = self.completed,
		total = self.batchTotal,
		usedThisMinute = self.limiter:Used(self.deps.now()),
		maxPerMinute = self.limiter.max,
	}
end

-- Queues targets (duplicates and already-queued targets are skipped).
-- Returns the number added.
function ScannerScheduler:EnqueueLookups(targets)
	if not self.inFlight and #self.queue == 0 then
		self.completed = 0
		self.batchTotal = 0
	end
	local added = 0
	for i = 1, #targets do
		local target = targets[i]
		if target and target.id and not self:IsQueued(target.id) then
			target.retries = 0
			self.queue[#self.queue + 1] = target
			added = added + 1
		end
	end
	self.batchTotal = self.batchTotal + added
	if added > 0 then
		self:Fire("LOOKUP_STATE_CHANGED", self:GetLookupStatus())
	end
	self:Pump()
	return added
end

function ScannerScheduler:CancelLookups()
	local hadWork = self.inFlight ~= nil or #self.queue > 0
	self.queue = {}
	self.inFlight = nil
	self.lookupGeneration = self.lookupGeneration + 1
	self.rateTimerPending = false
	self:SetState(ScannerScheduler.STATE_IDLE)
	return hadWork
end

function ScannerScheduler:Pump()
	if self.inFlight then
		return
	end
	if #self.queue == 0 then
		self:SetState(ScannerScheduler.STATE_IDLE)
		return
	end
	if not self.deps.isThrottleReady() then
		self:SetState(ScannerScheduler.STATE_WAITING_THROTTLE)
		return -- OnThrottleReady() resumes
	end

	local ok, wait = self.limiter:TryAcquire(self.deps.now())
	if not ok then
		self:SetState(ScannerScheduler.STATE_WAITING_RATE_LIMIT)
		if not self.rateTimerPending then
			self.rateTimerPending = true
			local generation = self.lookupGeneration
			self.deps.after(math.max(wait, 0.05), function()
				if generation ~= self.lookupGeneration then
					return
				end
				self.rateTimerPending = false
				self:Pump()
			end)
		end
		return
	end

	local target = table.remove(self.queue, 1)
	self.inFlight = target
	self.lookupGeneration = self.lookupGeneration + 1
	local generation = self.lookupGeneration
	self.rateTimerPending = false
	self:SetState(ScannerScheduler.STATE_WAITING_RESPONSE)

	local sent, sendOk = pcall(self.deps.sendSearch, target)
	if not sent or sendOk == false then
		self:Complete(target, ScannerScheduler.RESULT_SEND_FAILED)
		return
	end
	self:Fire("LOOKUP_SENT", target)

	self.deps.after(self.responseTimeout, function()
		if generation == self.lookupGeneration and self.inFlight == target then
			self:Complete(target, ScannerScheduler.RESULT_TIMEOUT)
		end
	end)
end

function ScannerScheduler:Complete(target, result)
	if self.inFlight == target then
		self.inFlight = nil
	end
	self.lookupGeneration = self.lookupGeneration + 1
	self.completed = self.completed + 1
	self:Fire("LOOKUP_DONE", target, result)
	self:Pump()
end

-- Call when listing results for groupKey arrive (from either source).
function ScannerScheduler:OnSearchResults(groupKey)
	local target = self.inFlight
	if not target or not target.matchKeys then
		return false
	end
	for i = 1, #target.matchKeys do
		if target.matchKeys[i] == groupKey then
			self:Complete(target, ScannerScheduler.RESULT_OK)
			return true
		end
	end
	return false
end

-- AUCTION_HOUSE_THROTTLED_SYSTEM_READY
function ScannerScheduler:OnThrottleReady()
	if self.state == ScannerScheduler.STATE_WAITING_THROTTLE then
		self:Pump()
	end
end

-- AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED: re-queue the in-flight lookup.
function ScannerScheduler:OnMessageDropped()
	local target = self.inFlight
	if not target then
		return
	end
	self.inFlight = nil
	self.lookupGeneration = self.lookupGeneration + 1
	if target.retries < self.maxRetries then
		target.retries = target.retries + 1
		table.insert(self.queue, 1, target)
		self:SetState(ScannerScheduler.STATE_WAITING_THROTTLE)
		if self.deps.isThrottleReady() then
			self:Pump()
		end
	else
		self.completed = self.completed + 1
		self:Fire("LOOKUP_DONE", target, ScannerScheduler.RESULT_DROPPED)
		self:Pump()
	end
end
