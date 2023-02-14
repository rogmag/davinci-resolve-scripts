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


	Currently the Media Pool in DaVinci Resolve doesn't have a way of showing whether a timeline
	uses custom timeline settings or inherits from the project timeline settings. If it's not an
	obvious difference, like a difference in resolution, you'd have to check the settings for each
	one to find them all.

	This script lists the timelines that have the "Use Project Settings" checkbox unchecked.
	Double click a timeline to switch to it.

	roger.magnusson@gmail.com


]]

local script =
{
	name = "Timelines with Custom Settings",
	version = "1.0",
	window_id = "CustomTimelines",
	ui = app.UIManager,
	dispatcher = bmd.UIDispatcher(app.UIManager)
}

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
			WindowMaximizeButtonHint = true,
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

		FixedSize = { 350, 400 },
		
		ui:VGroup
		{
			Weight = 1,
			Spacing = 10,

			ui:Tree
			{
				Weight = 1,
				ID = "TimelinesTreeView", 
				AlternatingRowColors = true,
				RootIsDecorated = false,
				SortingEnabled = true,
				Events = { ItemDoubleClicked = true },
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Weight = 1,
					ID = "StatusLabel",
				},

				ui:Button
				{
					Weight = 0,
					ID = "CloseButton",
					Text = "Close",
					AutoDefault = false,
					Default = true,
				},
			},
		},
	})

	window_items = window:GetItems()

	window.On.TimelinesTreeView.ItemDoubleClicked = function(ev)
		-- Exit the UI loop and return the index of the clicked timeline
		dispatcher:ExitLoop(ev.item:GetData(0, "UserRole"))
	end

	window.On.CloseButton.Clicked = function(ev)
		-- Exit the UI loop without returning anything
		dispatcher:ExitLoop()
	end
	
	window.On[script.window_id].KeyPress = function(ev)
		if (ev.Key == 16777216) then -- Escape
			window_items.CloseButton:Click()
		end
	end

	window.On[script.window_id].Close = function(ev)
		window_items.CloseButton:Click()
	end

	return window, window_items
end

local function main()
	local project = assert(resolve:GetProjectManager():GetCurrentProject(), "Couldn't get current project")
	local current_timeline = assert(project:GetCurrentTimeline(), "Couldn't get current timeline")
	local timeline_count = project:GetTimelineCount()
	local window, window_items = create_window()

	for i = 1, timeline_count do
		local timeline = project:GetTimelineByIndex(i)

		-- If the timeline is using custom settings, 
		-- create a treeview item and add it to the treeview
		if timeline:GetSetting("useCustomSettings") == "1" then
			local item = window_items.TimelinesTreeView:NewItem()
			item.Text[0] = timeline:GetName()
			item:SetData(0, "UserRole", i) -- Store the index of the timeline in the data for column 0

			window_items.TimelinesTreeView:AddTopLevelItem(item)

			if timeline == current_timeline then
				item.Selected = true
			end
		end
	end

	window_items.TimelinesTreeView:SetHeaderLabel("Name")
	window_items.TimelinesTreeView:SortByColumn(0, "AscendingOrder")
	window_items.StatusLabel.Text = string.format("%d/%d Timelines", window_items.TimelinesTreeView:TopLevelItemCount(), timeline_count)
	window:Show()
	
	-- Run the UI loop where it will wait for events
	local timeline_index = script.dispatcher:RunLoop()

	window:Hide()

	if timeline_index then
		local current_page = resolve:GetCurrentPage()		

		-- Only switch to the selected timeline if we're on a suitable page
		if current_page ~= "media" and current_page ~= "fusion" then
			project:SetCurrentTimeline(project:GetTimelineByIndex(timeline_index))
		end
	end
end

main()
