--[[
Categories: maps item classes to Vendor Sniper categories.

Pure module. Item class IDs match Enum.ItemClass in the Forever client
(ItemConstantsDocumentation, build 70938). Call Categories.Init(Enum.ItemClass)
in-game to pick up the live values in case they ever differ.

To add a category later, append to Categories.ORDER, give it a label, and
map its classes in DEFAULT_CLASS_MAP.
]]
local _, ns = ...

local Categories = {}
ns.Categories = Categories

Categories.EQUIPMENT = "equipment"
Categories.MATERIAL = "material"
Categories.CONSUMABLE = "consumable"

-- Display order and the set of known categories.
Categories.ORDER = { Categories.EQUIPMENT, Categories.MATERIAL, Categories.CONSUMABLE }

Categories.LABELS = {
	[Categories.EQUIPMENT] = "Equipment",
	[Categories.MATERIAL] = "Material",
	[Categories.CONSUMABLE] = "Consumable",
}

-- Enum.ItemClass names -> category.
local DEFAULT_CLASS_MAP = {
	Weapon = Categories.EQUIPMENT,
	Armor = Categories.EQUIPMENT,
	Tradegoods = Categories.MATERIAL,
	Reagent = Categories.MATERIAL,
	Consumable = Categories.CONSUMABLE,
}

-- Fallback values from the Forever API documentation.
local DEFAULT_ITEM_CLASS = {
	Consumable = 0,
	Weapon = 2,
	Armor = 4,
	Reagent = 5,
	Tradegoods = 7,
}

local classToCategory = {}

-- (Re)builds the classID -> category table. itemClassEnum is optional.
function Categories.Init(itemClassEnum)
	classToCategory = {}
	for className, category in pairs(DEFAULT_CLASS_MAP) do
		local id = itemClassEnum and itemClassEnum[className]
		if type(id) ~= "number" then
			id = DEFAULT_ITEM_CLASS[className]
		end
		classToCategory[id] = category
	end
end

-- Returns the category for an item, or nil when it isn't a supported category.
-- isEquipment (from ItemKeyInfo) is used when classID is unknown.
function Categories.FromClassID(classID, isEquipment)
	if type(classID) == "number" then
		local category = classToCategory[classID]
		if category then
			return category
		end
		return nil
	end
	if isEquipment then
		return Categories.EQUIPMENT
	end
	return nil
end

function Categories.Label(category)
	return Categories.LABELS[category] or "Other"
end

function Categories.IsKnown(category)
	return Categories.LABELS[category] ~= nil
end

Categories.Init(nil)
