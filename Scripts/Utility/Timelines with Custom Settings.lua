--[[
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

	local window = dispatcher:AddWindow(
	{
		ID = script.window_id,
		WindowTitle = script.name,
		WindowFlags =
		{
			Dialog = true,
			WindowTitleHint = true,
			WindowCloseButtonHint = true,
		},

		WindowModality = "WindowModal",

		Events = 
		{
			Close = true,
			KeyPress = true,
		},

		FixedSize = { 300, 400 },
		
		ui:VGroup
		{
			Weight = 1,

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
