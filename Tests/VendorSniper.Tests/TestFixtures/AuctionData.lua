--[[
A small Auction House state using the exact Forever API field names.
Returns a fresh table on every call, so tests can modify it freely.

  2589  Linen Cloth        commodity, material,  vendor 13c, stack 20
  2207  Jambiya            item,      equipment, vendor 77c, stack 1
  118   Minor Healing Pot. commodity, consumable, vendor 5c, stack 5
  4000  Test Scroll        item (stackable non-commodity), consumable, vendor 1s, stack 10
  6000  Test Recipe        item, recipe (unsupported category), vendor 50c
  7000  Test Junk          commodity, material, vendor 0 (can't be sold)
]]
local ns = ...

local function key(itemID)
	return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

local JAMBIYA_LINK = "|cffffffff|Hitem:2207::::::::20:::::::::|h[Jambiya]|h|r"

return {
	items = {
		[2589] = { name = "Linen Cloth", link = "[Linen Cloth]", quality = 1, maxStack = 20, icon = 1, sellPrice = 13, classID = 7, subClassID = 5 },
		[2207] = { name = "Jambiya", link = "[Jambiya]", quality = 1, maxStack = 1, icon = 2, sellPrice = 77, classID = 2, subClassID = 15 },
		[118] = { name = "Minor Healing Potion", link = "[Minor Healing Potion]", quality = 1, maxStack = 5, icon = 3, sellPrice = 5, classID = 0, subClassID = 1 },
		[4000] = { name = "Test Scroll", link = "[Test Scroll]", quality = 1, maxStack = 10, icon = 4, sellPrice = 100, classID = 0, subClassID = 4 },
		[6000] = { name = "Test Recipe", link = "[Test Recipe]", quality = 2, maxStack = 1, icon = 5, sellPrice = 50, classID = 9, subClassID = 0 },
		[7000] = { name = "Test Junk", link = "[Test Junk]", quality = 0, maxStack = 20, icon = 6, sellPrice = 0, classID = 7, subClassID = 0 },
	},
	keyInfo = {
		[2589] = { itemID = 2589, battlePetSpeciesID = 0, itemName = "Linen Cloth", quality = 1, iconFileID = 1, isPet = false, isCommodity = true, isEquipment = false },
		[2207] = { itemID = 2207, battlePetSpeciesID = 0, itemName = "Jambiya", quality = 1, iconFileID = 2, isPet = false, isCommodity = false, isEquipment = true },
		[118] = { itemID = 118, battlePetSpeciesID = 0, itemName = "Minor Healing Potion", quality = 1, iconFileID = 3, isPet = false, isCommodity = true, isEquipment = false },
		[4000] = { itemID = 4000, battlePetSpeciesID = 0, itemName = "Test Scroll", quality = 1, iconFileID = 4, isPet = false, isCommodity = false, isEquipment = false },
		[6000] = { itemID = 6000, battlePetSpeciesID = 0, itemName = "Test Recipe", quality = 2, iconFileID = 5, isPet = false, isCommodity = false, isEquipment = false },
		[7000] = { itemID = 7000, battlePetSpeciesID = 0, itemName = "Test Junk", quality = 0, iconFileID = 6, isPet = false, isCommodity = true, isEquipment = false },
	},
	browse = {
		{ itemKey = key(2589), totalQuantity = 360, minPrice = 10, containsOwnerItem = false },
		{ itemKey = key(2207), totalQuantity = 4, minPrice = 50, containsOwnerItem = false },
		{ itemKey = key(118), totalQuantity = 50, minPrice = 8, containsOwnerItem = false },
		{ itemKey = key(4000), totalQuantity = 30, minPrice = 500, containsOwnerItem = false },
		{ itemKey = key(6000), totalQuantity = 1, minPrice = 1, containsOwnerItem = false },
		{ itemKey = key(7000), totalQuantity = 99, minPrice = 1, containsOwnerItem = false },
	},
	itemRows = {
		["2207:0:0:0"] = {
			{ itemKey = key(2207), auctionID = 101, quantity = 1, buyoutAmount = 50, itemLink = JAMBIYA_LINK, owners = {}, totalNumberOfOwners = 1, timeLeft = 2, containsOwnerItem = false, containsAccountItem = false, containsSocketedItem = false },
			{ itemKey = key(2207), auctionID = 102, quantity = 1, buyoutAmount = 60, itemLink = JAMBIYA_LINK, owners = {}, totalNumberOfOwners = 1, timeLeft = 2, containsOwnerItem = false, containsAccountItem = false, containsSocketedItem = false },
			{ itemKey = key(2207), auctionID = 103, quantity = 1, minBid = 20, itemLink = JAMBIYA_LINK, owners = {}, totalNumberOfOwners = 1, timeLeft = 1, containsOwnerItem = false, containsAccountItem = false, containsSocketedItem = false },
			{ itemKey = key(2207), auctionID = 104, quantity = 1, buyoutAmount = 200, itemLink = JAMBIYA_LINK, owners = {}, totalNumberOfOwners = 1, timeLeft = 3, containsOwnerItem = false, containsAccountItem = false, containsSocketedItem = false },
		},
		["4000:0:0:0"] = {
			{ itemKey = key(4000), auctionID = 401, quantity = 10, buyoutAmount = 500, owners = {}, totalNumberOfOwners = 1, timeLeft = 2, containsOwnerItem = false, containsAccountItem = false, containsSocketedItem = false },
			{ itemKey = key(4000), auctionID = 402, quantity = 2, buyoutAmount = 600, owners = {}, totalNumberOfOwners = 1, timeLeft = 2, containsOwnerItem = false, containsAccountItem = false, containsSocketedItem = false },
		},
	},
	commodityRows = {
		[2589] = {
			{ itemID = 2589, quantity = 20, unitPrice = 10, auctionID = 900, owners = {}, totalNumberOfOwners = 1, numOwnerItems = 0, containsOwnerItem = false, containsAccountItem = false },
			{ itemID = 2589, quantity = 40, unitPrice = 10, auctionID = 901, owners = {}, totalNumberOfOwners = 2, numOwnerItems = 0, containsOwnerItem = false, containsAccountItem = false },
			{ itemID = 2589, quantity = 100, unitPrice = 12, auctionID = 902, owners = {}, totalNumberOfOwners = 3, numOwnerItems = 0, containsOwnerItem = false, containsAccountItem = false },
			{ itemID = 2589, quantity = 200, unitPrice = 15, auctionID = 903, owners = {}, totalNumberOfOwners = 5, numOwnerItems = 0, containsOwnerItem = false, containsAccountItem = false },
		},
	},
}
