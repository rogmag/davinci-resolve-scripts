--[[

MIT License

Copyright (c) 2023 Roger Magnusson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

-----------------------------------------------------------------------------


	This script performs batch color changes of timeline markers. It does that by removing and
	recreating markers with your selected color. You can use specific colors, random or cycle
	through all available colors in order.

	Note that Resolve 18 doesn't support adding keywords to markers through the API. This means
	that any changed markers will have their keywords removed.

	roger.magnusson@gmail.com


]]

local script, luaresolve

script = 
{
	filename = debug.getinfo(1,"S").source:match("^.*%@(.*)"),
	version = "1.0",
	name = "Change Timeline Marker Colors",
	window_id = "ChangeTimelineMarkerColors",

	settings =
	{
		from_marker_color = "Any",
		to_marker_color = "Blue"
	},

	load_settings = function(self)
		local settings_filename = self.filename:gsub(".lua", ".settings")

		if (bmd.fileexists(settings_filename)) then
			self.settings = bmd.readfile(settings_filename)
		end
	end,

	save_settings = function(self)
		bmd.writefile(self.filename:gsub(".lua", ".settings"), self.settings)
	end,

	ui = app.UIManager,
	dispatcher = bmd.UIDispatcher(app.UIManager)
}

luaresolve = 
{
	markers =
	{
		get_marker_count_by_color = function(markers)
			local marker_count_by_color = { Any = 0 }

			for marker_frame, marker in pairs(markers) do
				if marker_count_by_color[marker.color] == nil then
					marker_count_by_color[marker.color] = 0
				end

				marker_count_by_color[marker.color] = marker_count_by_color[marker.color] + 1
				marker_count_by_color.Any = marker_count_by_color.Any + 1
			end

			return marker_count_by_color
		end,

		colors = 
		{
			"Blue",
			"Cyan",
			"Green",
			"Yellow",
			"Red",
			"Pink",
			"Purple",
			"Fuchsia",
			"Rose",
			"Lavender",
			"Sky",
			"Mint",
			"Lemon",
			"Sand",
			"Cocoa",
			"Cream"
		}
	},
}

script:load_settings()

local function create_window(marker_count_by_color)
	local ui = script.ui
	local dispatcher = script.dispatcher
	local window_flags = nil

	if ffi.os == "Windows" then
		window_flags = 	
		{
			Window = true,
			CustomizeWindowHint = true,
			WindowCloseButtonHint = true,
		}
	elseif ffi.os == "Linux" then
		window_flags = 
		{
			Window = true,
		}
	elseif ffi.os == "OSX" then
		window_flags = 
		{
			Dialog = true,
		}
	end

	local window = dispatcher:AddDialog(
	{
		ID = script.window_id,
		WindowTitle = script.name,
		WindowFlags = window_flags,

		WindowModality = "ApplicationModal",

		Events = 
		{
			Close = true,
			KeyPress = true,
		},

		FixedSize = { 400, 150 },

		ui:VGroup
		{
			Weight = 1,
			MinimumSize = { 380, 130 },
			MaximumSize = { 380, 130 },

			ui:VGap(0, 1),

			ui:HGroup
			{
				Weight = 0,
				Spacing = 10,

				ui:Label
				{
					Weight = 0,
					Alignment = { AlignVCenter = true },
					Text = "From Color"
				},

				ui:ComboBox
				{
					Weight = 1,
					ID = "FromMarkerColorComboBox",
				},

				ui:HGap(1),

				ui:Label
				{
					Weight = 0,
					Alignment = { AlignVCenter = true },
					Text = "To Color"
				},

				ui:ComboBox
				{
					Weight = 1,
					ID = "ToMarkerColorComboBox",
				},
			},

			ui:HGroup
			{
				Weight = 0,
				Spacing = 10,

				ui:Label
				{
					Weight = 1,
					Alignment = { AlignCenter = true },
					ID = "InfoLabel",
					StyleSheet = [[
						QLabel
						{
							margin-top: 10px;
						}
					]],
				},
			},

			ui:VGap(0, 1),

			ui:HGroup
			{
				Weight = 0,
				Spacing = 10,
				StyleSheet = [[
					QPushButton
					{
						min-height: 22px;
						max-height: 22px;
						min-width: 108px;
						max-width: 108px;
					}
				]],

				ui:HGap(0, 1),

				ui:Button
				{
					Weight = 0,
					ID = "CancelButton",
					Text = "Cancel",
					AutoDefault = false,
				},

				ui:Button
				{
					Weight = 0,
					ID = "StartButton",
					Text = "Start",
					AutoDefault = false,
					Default = true,
				},
			},
		},
	})

	window_items = window:GetItems()

	local function update_controls()
		local start_button_enabled = true
		local marker_count = marker_count_by_color[window_items.FromMarkerColorComboBox.CurrentText]

		if marker_count ~= nil and marker_count > 0 then
			window_items.InfoLabel.Text = string.format("%s marker%s will be changed", marker_count, iif(marker_count == 1, "", "s"))
		else
			local marker_color = iif(window_items.FromMarkerColorComboBox.CurrentText == "Any", "", window_items.FromMarkerColorComboBox.CurrentText:lower().." ")
			window_items.InfoLabel.Text = string.format("No %s markers found", marker_color)
			start_button_enabled = false
		end

		window_items.StartButton.Enabled = start_button_enabled
	end

	local function initialize_controls()
		window.StyleSheet = [[
			QComboBox
			{
				min-height: 18px;
				max-height: 18px;
			}
		]]

		window_items.FromMarkerColorComboBox:AddItem("Any")
		window_items.FromMarkerColorComboBox:AddItems(luaresolve.markers.colors)
		window_items.FromMarkerColorComboBox:InsertSeparator(1)
		window_items.FromMarkerColorComboBox.CurrentText = script.settings.from_marker_color

		window_items.ToMarkerColorComboBox:AddItems(luaresolve.markers.colors)
		window_items.ToMarkerColorComboBox:AddItem("Random")
		window_items.ToMarkerColorComboBox:AddItem("Cycle")
		window_items.ToMarkerColorComboBox:InsertSeparator(#luaresolve.markers.colors)
		window_items.ToMarkerColorComboBox.CurrentText = script.settings.to_marker_color

		update_controls()
	end

	initialize_controls()

	window.On.FromMarkerColorComboBox.CurrentIndexChanged = function(ev)
		update_controls()
	end

	window.On.ToMarkerColorComboBox.CurrentIndexChanged = function(ev)
		update_controls()
	end

	window.On.CancelButton.Clicked = function(ev)
		dispatcher:ExitLoop(false)
	end

	window.On.StartButton.Clicked = function(ev)
		script.settings.from_marker_color = window_items.FromMarkerColorComboBox.CurrentText
		script.settings.to_marker_color = window_items.ToMarkerColorComboBox.CurrentText
		script:save_settings()

		dispatcher:ExitLoop(true)
	end
	
	window.On[script.window_id].Close = function(ev)
		window_items.CancelButton:Click()
	end

	return window
end

local function main()
	local project = assert(resolve:GetProjectManager():GetCurrentProject(), "Couldn't get current project")
	local timeline = assert(project:GetCurrentTimeline(), "Couldn't get current timeline")
	local markers = timeline:GetMarkers()

	if next(markers) ~= nil then
		local window = create_window(luaresolve.markers.get_marker_count_by_color(markers))

		window:Show()
		local change_colors = script.dispatcher:RunLoop()
		window:Hide()

		if change_colors then
			-- We're storing the current page because Resolve will automatically switch to the Edit page when adding markers.
			-- However, it doesn't switch if we start on the Color page, but then it has an issue where the changed markers
			-- aren't redrawn until the user clicks the Color page timeline.
			-- To avoid this we will force a switch to the Edit page regardless. Note that undoing marker changes doesn't work
			-- on the Color page, but you can switch to one of the other pages to undo (not a scripting issue, it's how Resolve works).
			local initial_page = resolve:GetCurrentPage()
			resolve:OpenPage("edit")

			local changed_marker_count = 0

			-- Create a new table that will contain ordered marker frames
			local marker_frames = {}
			
			-- Add the marker frames to the table
			for marker_frame, _ in pairs(markers) do
				marker_frames[#marker_frames+1] = marker_frame
			end
			
			-- Sort the table
			table.sort(marker_frames)

			-- Now we can process the markers in order
			for _, marker_frame in ipairs(marker_frames) do
				local marker = markers[marker_frame]

				if script.settings.from_marker_color == "Any" or script.settings.from_marker_color == marker.color then
					changed_marker_count = changed_marker_count + 1
					local color = script.settings.to_marker_color

					if color == "Random" then
						color = luaresolve.markers.colors[math.random(#luaresolve.markers.colors)]
					elseif color == "Cycle" then
						color = luaresolve.markers.colors[1 + (changed_marker_count - 1) % #luaresolve.markers.colors]
					end

					-- Markers can't be updated using the current API, so we'll delete and recreate them instead
					timeline:DeleteMarkerAtFrame(marker_frame)
					timeline:AddMarker(marker_frame, color, marker.name, marker.note, marker.duration, marker.customData)
				end
			end

			resolve:OpenPage(initial_page)
		end
	end
end

main()
