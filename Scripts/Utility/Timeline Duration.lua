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
		get_fraction = function(self, frame_rate_string_or_number)
			local frame_rate = tonumber(tostring(frame_rate_string_or_number))
			-- These are the frame rates that DaVinci Resolve Studio supports as of version 18
			local frame_rates = { 16, 18, 23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60, 72, 95.904, 96, 100, 119.88, 120 }

			for _, current_frame_rate in ipairs (frame_rates) do
				if current_frame_rate == frame_rate or math.floor(current_frame_rate) == frame_rate then
					local is_decimal = current_frame_rate % 1 > 0
					local denominator = iif(is_decimal, 1001, 100)
					local numerator = math.ceil(current_frame_rate) * iif(is_decimal, 1000, denominator)
					return { num = numerator, den = denominator }
				end
			end

			return nil, string.format("Invalid frame rate: %s", frame_rate_string_or_number)
		end,

		get_decimal = function(self, frame_rate_string_or_number)
			local fractional_frame_rate, error_message = self:get_fraction(frame_rate_string_or_number)
			
			if fractional_frame_rate ~= nil then
				return tonumber(string.format("%.3f", fractional_frame_rate.num / fractional_frame_rate.den))
			else
				return nil, error_message
			end
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

		-- Time is rounded to the nearest millisecond
		local total_milliseconds = tonumber(string.format("%.0f", 1000 * frame / (fractional_frame_rate.num / fractional_frame_rate.den)))
		
		local hours = math.floor(total_milliseconds / 1000 / 60 / 60)
		local minutes = math.floor(total_milliseconds / 1000 / 60) % 60
		local seconds = math.floor(total_milliseconds / 1000) % 60
		local milliseconds = total_milliseconds % 1000
		
		return
		{
			time = string.format("%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds),
			hours = hours,
			minutes = minutes,
			seconds = seconds,
			milliseconds = milliseconds,
			total_milliseconds = total_milliseconds,
		}
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

				ui:Label
				{
					Weight = 1,
					ID = "Playhead",
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
		dispatcher:ExitLoop(ev.item:GetData(0, "DisplayRole"))
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
	local current_frame_rate = luaresolve.frame_rates:get_decimal(current_timeline:GetSetting("timelineFrameRate"))
	local current_timecode = current_timeline:GetCurrentTimecode()
	local current_frame = luaresolve:frame_from_timecode(current_timecode, current_frame_rate)
	local timeline_count = project:GetTimelineCount()
	local window, window_items = create_window()

	window_items.TimelinesTreeView.ColumnCount = 6
	window_items.TimelinesTreeView.ColumnWidth[0] = 35
	window_items.TimelinesTreeView.ColumnWidth[1] = 180
	window_items.TimelinesTreeView.ColumnWidth[2] = 70
	window_items.TimelinesTreeView.ColumnWidth[3] = 80

	for i = 1, timeline_count do
		local timeline = project:GetTimelineByIndex(i)
		local item = window_items.TimelinesTreeView:NewItem()
		local frames = timeline:GetEndFrame() - timeline:GetStartFrame()
		local frame_rate = luaresolve.frame_rates:get_decimal(timeline:GetSetting("timelineFrameRate"))
		local drop_frame = timeline:GetSetting("timelineDropFrameTimecode") == "1"

		item:SetData(0, "DisplayRole", i) -- We're using SetData instead of Text so we can get the natural sort order of numbers
		item:SetData(1, "DisplayRole", timeline:GetName())
		item:SetData(2, "DisplayRole", frames)
		item:SetData(3, "DisplayRole", string.format("%.3f%s", frame_rate, iif(drop_frame, " DF", ""))) -- If you want to sort 100fps and above correctly, add leading zeros using the string format "%07.3f%s", or don't convert this column to a string and use a separate column for indicating drop frame
		item:SetData(4, "DisplayRole", luaresolve:timecode_from_frame(frames, frame_rate, drop_frame))
		item:SetData(5, "DisplayRole", luaresolve:time_from_frame(frames, frame_rate).time)

		-- Change the text color when using a fractional frame rate
		if frame_rate % 1 > 0 then
			item.TextColor[5] = { R = 0.831, G = 0.678, B = 0.122, A = 1 }
		end

		window_items.TimelinesTreeView:AddTopLevelItem(item)

		if timeline == current_timeline then
			item.Selected = true
		end
	end

	window_items.TimelinesTreeView:SetHeaderLabels( { "ID", "Name", "Frames", "FPS", "Duration (TC)", "Duration (Time)" } )
	window_items.TimelinesTreeView:SortByColumn(1, "AscendingOrder")

	window_items.Playhead.Text = string.format("<pre>Current Frame: <span style='color: white'>%s</span>   TC: <span style='color: white;'>%s</span>   Time: <span style='%s'>%s</span></pre>",
		current_frame,
		current_timecode,
		iif(current_frame_rate % 1 > 0, "color: rgb(212, 173, 31);", "color: white;"),
		luaresolve:time_from_frame(current_frame - current_timeline:GetStartFrame(), current_frame_rate).time
	)

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
