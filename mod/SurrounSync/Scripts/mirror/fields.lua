-- Field names of the game's inventory item struct (Blueprint names carry a GUID suffix), for every module that reads
-- items: one copy, so a game update that renames a field is one edit. A misspelt key fails when the module loads,
-- not as a silent nil field name.

return setmetatable({
    ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B",
    INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7",
    ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
    COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD",
    DURABILITY = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA",
    UID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68",
    SLOT_INDEX = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD",
    ROTATED = "Rotated_9_3CFE5D9342A81FB1FF17DEB7B491CE56",
    PICKUP_REF = "PickupRef_20_A3E97763428AC84AF4DBB8A56CFAC657",
    ITEM_VEC = "ItemVec_13_4DB12E4E4F80730BD25ACFA6FA51AD0A",
    WEIGHT = "Weight_16_C6B7568A4E062D2AE81209916A32B4EB",
    PRICE = "Price_19_FEFE0D2A4561BAF04CE37D9BAE1D6EF7",
    PENDING = "Pending?_31_C3AE39044666796C0FA128BA521590CB",
    IS_CONTAINER = "IsContainer_14_0198F62E4F1B93DD8B4D6E92B7E3EA45",
    MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D",
    IN_INDEX = "InContainerIndex_31_A61F5C3A47C8E761BA5CF0ADA1DF9FDE",
}, { __index = function(_, k) error("mirror.fields has no field " .. tostring(k), 2) end })
