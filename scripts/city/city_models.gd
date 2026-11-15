class_name CityModels
extends RefCounted
## Все модели города в одном месте. Чтобы заменить пак (например, на купленный),
## достаточно поменять имена здесь и путь в city_kit.gd — генератор города трогать не нужно.
##
## Имена — это файлы из assets/downtown без расширения (.gltf).
## Модели машин трафика задаются отдельно, в vehicle_models.gd.
##
## Детали фасадов рассчитаны на шаг 2 м по ширине и 3 м по высоте (один этаж).

## Плитка тротуара 3×3 м, бордюр с одной стороны
const SIDEWALK_TILE := "Sidewalk_Straight_3m"

## Двери, которые ставятся в дверные проёмы (заходить внутрь нельзя, это просто полотно двери).
## Модель двери шириной 1 м, сдвиг ставит её в середину проёма шириной 2 м.
const DOORS: Array[String] = ["Door_1", "Door_2", "Door_3"]
const DOOR_OFFSET := Vector3(0.5, 0.0, -0.1)

## Колонны на углах собранных зданий: нижний этаж, средние, верхний
const COLUMN_BOTTOM := "Trim_Column_Bottom"
const COLUMN_MIDDLE := "Trim_Column_Center"
const COLUMN_TOP := "Trim_Column_Top"

## Готовые здания из пака: имя модели
const PREBUILT_TALL: Array[String] = ["Building_Large_2", "Building_Medium_2_001"]
const PREBUILT_LOW: Array[String] = ["Building_Small_1", "Building_Medium_2_001"]

## Наборы деталей для зданий, которые собираются из кусков.
## Стены бывают шириной 2 м и 4 м (широкие окна), высота всегда 3 м — один этаж.
## Первый этаж (ground) — только детали шириной 2 м.
const STYLE_BRICK := {
	"name": "brick",
	"ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Window", "Trim_FirstFloor_Window_001"],
	"door": "DoorFrame_Metal_Single",
	"upper": ["Brick_Window_Trim", "Brick_Window_Trim_Single", "Brick_Window_Square_Single"],
	"cornice": "Cornice_Brick_Center",
}
const STYLE_BRICK_ARCH := {
	"name": "brick_arch",
	"ground": ["Trim_FirstFloor_Window_001", "Trim_FirstFloor_Window_001", "Trim_FirstFloor_Wall"],
	"door": "DoorFrame_Trim",
	"upper": ["Brick_Window_CurvedDouble", "Brick_Window_Trim"],
	"cornice": "Cornice_Trim_Center",
}
const STYLE_BRICK_INSET := {
	"name": "brick_inset",
	"ground": ["Metal_FirstFloor_Window", "Trim_FirstFloor_Window_001"],
	"door": "DoorFrame_Metal_Single",
	"upper": ["Brick_Inset_Window", "Brick_Inset_Window_Curved_Small", "Brick_Inset_Window"],
	"cornice": "Cornice_Brick_Center",
}
const STYLE_REDWHITE := {
	"name": "redwhite",
	"ground": ["Trim_FirstFloor_Window_001", "Metal_FirstFloor_Window"],
	"door": "DoorFrame_Trim",
	"upper": ["Brick_RedWhite_DoubleWindow"],
	"cornice": "Cornice_Brick_Center",
}
const STYLE_TRIM := {
	"name": "trim",
	"ground": ["Trim_FirstFloor_Window_001", "Trim_FirstFloor_Wall", "Trim_FirstFloor_Window_001"],
	"door": "DoorFrame_Trim",
	"upper": ["Trim_Window", "Trim_Window", "Brick_Window_Trim_Single"],
	"cornice": "Cornice_Trim_Center",
}
const STYLE_GLASS := {
	"name": "glass",
	"ground": ["Metal_FirstFloor_Window", "Metal_FullWindow"],
	"door": "DoorFrame_Metal_Single",
	"upper": ["Metal_FullWindow", "Metal_Window_Half", "Metal_FullWindow"],
	"cornice": "Cornice_Metal_Center",
}
const STYLE_OFFICE := {
	"name": "office",
	"ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Window"],
	"door": "DoorFrame_Metal_Single",
	"upper": ["Metal_Window", "Metal_Window", "Metal_FullWindow"],
	"cornice": "Cornice_Metal_Center",
}
const STYLE_WAREHOUSE := {
	"name": "warehouse",
	"ground": ["Metal_FirstFloor_Wall", "Metal_FirstFloor_Wall", "Metal_FirstFloor_Window"],
	"door": "DoorFrame_Metal_Single",
	"upper": ["Metal_Plain_3", "Metal_Plain_3", "Metal_Window"],
	"cornice": "Cornice_Metal_Center",
}

## Детали на крышах
const ROOF_AC := "Prop_ACUnit"
## Детали улиц
const MANHOLE := "Prop_ManholeCover"
const DRAIN := "Prop_Drain"
const BOLLARD := "Prop_Bollard"
const PLANTER := "Prop_Planter_Single"
