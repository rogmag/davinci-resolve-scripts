--[[
	roger.magnusson@gmail.com
]]

local script =
{
	name = "Timeline Duration",
	version = "1.0",
	window_id = "TimelineDuration",

	set_declarations = function()
		libavutil.set_declarations()
	end,

	ui = app.UIManager,
	dispatcher = bmd.UIDispatcher(app.UIManager)
}

luaresolve = 
{
	frame_rates =
	{
		get_fraction = function(self, fps_string_or_number)
			local str_fps = tostring(fps_string_or_number)    
			local frame_rates = { 16, 18, 23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60, 72, 95.904, 96, 100, 119.88, 120 }

			for _, frame_rate in ipairs (frame_rates) do
				if tostring(frame_rate) == str_fps or tostring(math.floor(frame_rate)) == str_fps then
					local is_decimal = frame_rate % 1 > 0
					local denominator = iif(is_decimal, 1001, 100)
					local numerator = math.ceil(frame_rate) * iif(is_decimal, 1000, denominator)
					return { num = numerator, den = denominator }
				end
			end

			return { num = nil, den = nil }
		end,

		get_decimal = function(self, frame_rate_value)
			local fraction = self:get_fraction(frame_rate_value)
			return tonumber(string.format("%.3f", fraction.num / fraction.den))
		end,
	},

	load_library = function(name_pattern)
		local files = bmd.readdir(fu:MapPath("FusionLibs:"..iif(ffi.os == "Windows", "", "../"))..name_pattern)
		assert(#files == 1 and files[1].IsDir == false, string.format("Couldn't find exact match for pattern \"%s.\"", name_pattern))
		return ffi.load(files.Parent..files[1].Name)
	end,

	frame_from_timecode = function(self, timecode, frame_rate)
		return libavutil:av_timecode_init_from_string(timecode, self.frame_rates:get_fraction(frame_rate)).start
	end,

	timecode_from_frame = function(self, frame, frame_rate, drop_frame)
		return libavutil:av_timecode_make_string(0, frame, self.frame_rates:get_decimal(frame_rate),
		{
			AV_TIMECODE_FLAG_DROPFRAME = drop_frame == true or drop_frame == 1 or drop_frame == "1",
			AV_TIMECODE_FLAG_24HOURSMAX = true,
			AV_TIMECODE_FLAG_ALLOWNEGATIVE = false
		})
	end,

	time_from_frame = function(self, frame, frame_rate)
		local fractional_frame_rate = self.frame_rates:get_fraction(frame_rate)
		local fps = fractional_frame_rate.num / fractional_frame_rate.den

		local hours = math.floor(frame / fps / 60 / 60)
		local minutes = math.floor(frame / fps / 60) % 60
		local seconds = math.floor(frame / fps) % 60
		local milliseconds = 1000 * frame / fps % 1000
		local milliseconds_rounded = tonumber(string.format("%.3f", milliseconds / 1000):sub(3))
		
		if math.ceil(milliseconds) == 1000 and milliseconds_rounded == 0 then
			if seconds == 59 then
				seconds = 0
				
				if minutes == 59 then
					minutes = 0
					hours = hours + 1
				else
					minutes = minutes + 1
				end
			else
				seconds = seconds + 1
			end
		end

		return string.format("%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds_rounded)
	end,
}

libavutil = 
{
	library = luaresolve.load_library(iif(ffi.os == "Windows", "avutil*.dll", iif(ffi.os == "OSX", "libavutil*.dylib", "libavutil.so"))),

	set_declarations = function()
		ffi.cdef[[
		enum AVTimecodeFlag {
			AV_TIMECODE_FLAG_DROPFRAME      = 1<<0, // timecode is drop frame
			AV_TIMECODE_FLAG_24HOURSMAX     = 1<<1, // timecode wraps after 24 hours
			AV_TIMECODE_FLAG_ALLOWNEGATIVE  = 1<<2, // negative time values are allowed
		};

		struct AVRational { int32_t num; int32_t den; };
		struct AVTimecode { int32_t start; enum AVTimecodeFlag flags; struct AVRational rate; uint32_t fps; };

		char* av_timecode_make_string(const struct AVTimecode* tc, const char* buf, int32_t framenum);
		int32_t av_timecode_init_from_string(struct AVTimecode* tc, struct AVRational rate, const char* str, void* log_ctx);
	]]
	end,

	av_timecode_make_string = function(self, start, frame, fps, flags)
		local function bor_number_flags(enum_name, flags)
			local enum_value = 0    
	
			if (flags) then
				for key, value in pairs(flags) do
					if (value == true) then
						enum_value = bit.bor(enum_value, tonumber(ffi.new(enum_name, key)))
					end
				end
			end

			return enum_value;
		end

		local tc = ffi.new("struct AVTimecode",
		{
			start = start,
			flags = bor_number_flags("enum AVTimecodeFlag", flags),
			fps = math.ceil(luaresolve.frame_rates:get_decimal(fps))
		})
	
		local timecodestring = ffi.string(self.library.av_timecode_make_string(tc, ffi.string(string.rep(" ", 16)), frame))
	
		if (#timecodestring > 0) then
			return timecodestring
		else
			return nil
		end
	end,

	av_timecode_init_from_string = function(self, timecode, frame_rate_fraction)
		local tc = ffi.new("struct AVTimecode")
		local result = self.library.av_timecode_init_from_string(tc, ffi.new("struct AVRational", frame_rate_fraction), timecode, ffi.new("void*", nil))
	
		if (result == 0) then
			return
			{
				start = tc.start,
				flags =
				{
					AV_TIMECODE_FLAG_DROPFRAME = bit.band(tc.flags, ffi.C.AV_TIMECODE_FLAG_DROPFRAME) == ffi.C.AV_TIMECODE_FLAG_DROPFRAME,
					AV_TIMECODE_FLAG_24HOURSMAX = bit.band(tc.flags, ffi.C.AV_TIMECODE_FLAG_24HOURSMAX) == ffi.C.AV_TIMECODE_FLAG_24HOURSMAX,
					AV_TIMECODE_FLAG_ALLOWNEGATIVE = bit.band(tc.flags, ffi.C.AV_TIMECODE_FLAG_ALLOWNEGATIVE) == ffi.C.AV_TIMECODE_FLAG_ALLOWNEGATIVE,
				},
				rate =
				{
					num = tc.rate.num,
					den = tc.rate.den
				},
				fps = tc.fps
			}
		else
			error("avutil error code: "..result)
		end
	end
}

script.set_declarations()

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

		FixedSize = { 600, 400 },
		
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

				ui:HGap(0, 1),

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

	window_items.TimelinesTreeView.ColumnCount = 5

	for i = 1, timeline_count do
		local timeline = project:GetTimelineByIndex(i)
		local item = window_items.TimelinesTreeView:NewItem()
		local frames = timeline:GetEndFrame() - timeline:GetStartFrame()
		local frame_rate = luaresolve.frame_rates:get_decimal(timeline:GetSetting("timelineFrameRate"))
		local drop_frame = timeline:GetSetting("timelineDropFrameTimecode") == "1"

		item.Text[0] = timeline:GetName()
		item.Text[1] = tostring(frames)
		item.Text[2] = string.format("%s%s", frame_rate, iif(frame_rate % 29.97 == 0, iif(drop_frame, " DF", " NDF"), ""))
		item.Text[3] = luaresolve:timecode_from_frame(frames, frame_rate, drop_frame)
		item.Text[4] = luaresolve:time_from_frame(frames, frame_rate)
		item:SetData(0, "UserRole", i) -- Store the index of the timeline in the data for column 0

		window_items.TimelinesTreeView:AddTopLevelItem(item)

		if timeline == current_timeline then
			item.Selected = true
		end
	end

	window_items.TimelinesTreeView:SetHeaderLabels( { "Name", "Frames", "Frame Rate", "Duration (TC)", "Duration (Time)" } )
	window_items.TimelinesTreeView:SortByColumn(0, "AscendingOrder")
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
