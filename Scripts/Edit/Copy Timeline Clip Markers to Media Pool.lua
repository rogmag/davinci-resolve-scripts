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


	This script copies timeline clip markers to media pool items.

	Note that Resolve 18 doesn't support adding keywords to markers through the API. This means
	that any changed markers will have their keywords removed.

	roger.magnusson@gmail.com


]]

local script = 
{
	filename = debug.getinfo(1,"S").source:match("^.*%@(.*)"),
	version = "1.0",
	name = "Copy Timeline Clip Markers to Media Pool",
	window_id = "CopyTimelineClipMarkersToMediaPool",

	settings =
	{
		clear = false,
		overwrite = true,
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

script:load_settings()

local function create_window()
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

		FixedSize = { 420, 170 },

		ui:VGroup
		{
			Weight = 1,
			MinimumSize = { 400, 150 },
			MaximumSize = { 400, 150 },

			ui:VGap(0, 1),
			
			ui:HGroup
			{
				Weight = 0,

				ui:HGap(0, 1),

				ui:VGroup
				{
					Weight = 0,
					Spacing = 10,

					ui:CheckBox
					{
						Weight = 0,
						ID = "ClearCheckBox",
						Text = "Clear existing media pool clip markers",
						Events = { Toggled = true },
					},

					ui:CheckBox
					{
						Weight = 0,
						ID = "OverwriteCheckBox",
						Text = "Overwrite media pool clip markers if they're on the same frame",
					},
				},

				ui:HGap(0, 1),
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
		window_items.OverwriteCheckBox.Enabled = not window_items.ClearCheckBox.Checked
	end

	local function initialize_controls()
		window_items.ClearCheckBox.Checked = script.settings.clear
		window_items.OverwriteCheckBox.Checked = script.settings.overwrite

		update_controls()
	end

	initialize_controls()

	window.On.ClearCheckBox.Toggled = function(ev)
		update_controls()
	end

	window.On.CancelButton.Clicked = function(ev)
		dispatcher:ExitLoop(false)
	end

	window.On.StartButton.Clicked = function(ev)
		script.settings.clear = window_items.ClearCheckBox.Checked
		script.settings.overwrite = window_items.OverwriteCheckBox.Checked
		script:save_settings()

		dispatcher:ExitLoop(true)
	end
	
	window.On[script.window_id].Close = function(ev)
		window_items.CancelButton:Click()
	end

	return window
end

local function get_timeline_clip_markers_by_media_pool_item(timeline)
	local markers_by_media_pool_item = {}

	-- Collect all timeline clip markers where there's a matching media pool item.
	-- If there are markers on the same frame for both audio and video, the marker on the video clip is used.
	-- If there are multiple instances on the timeline of the same clip with markers on the same frame, the first encountered marker is used.
	for _, track_type in ipairs( { "video", "audio" } ) do
		for i = timeline:GetTrackCount(track_type), 1, -1 do
			for _, item in ipairs(timeline:GetItemListInTrack(track_type, i)) do
				local media_pool_item = item:GetMediaPoolItem()
				
				if media_pool_item then
					local unique_id = media_pool_item:GetUniqueId()
					local timeline_item_markers = item:GetMarkers()

					if not markers_by_media_pool_item[unique_id] then
						markers_by_media_pool_item[unique_id] =  { media_pool_item = media_pool_item, timeline_item_markers = timeline_item_markers }
					else
						for marker_frame, marker in pairs(timeline_item_markers) do
							if not markers_by_media_pool_item[unique_id].timeline_item_markers[marker_frame] then
								markers_by_media_pool_item[unique_id].timeline_item_markers[marker_frame] = marker
							end
						end
					end
				end
			end
		end
	end

	return markers_by_media_pool_item
end

local function main()
	local project = assert(resolve:GetProjectManager():GetCurrentProject(), "Couldn't get current project")
	local timeline = assert(project:GetCurrentTimeline(), "Couldn't get current timeline")
	local window = create_window()

	window:Show()
	local copy_markers = script.dispatcher:RunLoop()
	window:Hide()

	if copy_markers then
		for _, data in pairs(get_timeline_clip_markers_by_media_pool_item(timeline)) do
			local media_pool_item_markers = data.media_pool_item:GetMarkers()
			
			if window_items.ClearCheckBox.Checked then
				-- Clear all markers in the media pool item
				for marker_frame, marker in pairs(media_pool_item_markers) do
					data.media_pool_item:DeleteMarkerAtFrame(marker_frame)
				end

				media_pool_item_markers = data.media_pool_item:GetMarkers()
			end

			for marker_frame, marker in pairs(data.timeline_item_markers) do
				if media_pool_item_markers[marker_frame] and window_items.OverwriteCheckBox.Checked then
					-- Delete media pool item marker
					data.media_pool_item:DeleteMarkerAtFrame(marker_frame)
				end
			
				if window_items.OverwriteCheckBox.Checked == true or (window_items.OverwriteCheckBox.Checked == false and not media_pool_item_markers[marker_frame]) then
					-- Add timeline clip marker to media pool item
					data.media_pool_item:AddMarker(marker_frame, marker.color, marker.name, marker.note, marker.duration, marker.customData)
				end
			end
		end
	end
end

main()
