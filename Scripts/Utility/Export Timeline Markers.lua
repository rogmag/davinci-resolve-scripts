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


	A script for exporting timeline markers to various formats.

	roger.magnusson@gmail.com


]]

local script, stringex, luaresolve, libavutil

script =
{
	filename = debug.getinfo(1,"S").source:match("^.*%@(.*)"),
	name = "Export Timeline Markers",
	version = "1.0",
	window_id = "ExportTimelineMarkers",

	settings =
	{
		folder = "",
		format = "tab_delimited_text",
		force_start_at_zero = false,
		color = "Any",
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

	set_declarations = function()
		libavutil.set_declarations()
	end,

	ui = app.UIManager,
	dispatcher = bmd.UIDispatcher(app.UIManager)
}

stringex =
{
	quote_if_needed = function(val, force)
		local val_str = tostring(val)
		local needs_quote = val_str:find("\t") or val_str:find("\n") or val_str:find("\"")
		local escaped_val_str = val_str:gsub("\"", "\"\"")
		
		return iif(needs_quote or force, "\""..escaped_val_str.."\"", escaped_val_str)
	end,
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
		},

		formats = 
		{
			tab_delimited_text =
			{	-- This format isn't emulating any existing format for marker exports. In addition to common
				-- fields it adds "Duration (Time)" which isn't normally available in Resolve.
				-- The exported file can be opened directly in Excel without any special settings or parsing. For Google Spreadsheet... //TODO
				name = "Tab-delimited Text",
				extension = "txt",
				export_config =
				{
					fields = table.pack
					(
						{ name = "#",				value_field = "index",			value = function(self, marker_data) return marker_data[self.value_field] end },
						{ name = "Frame",			value_field = "frame",			value = function(self, marker_data) return marker_data[self.value_field] end },
						{ name = "Name",			value_field = "name",			value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field]) end },
						{ name = "Start TC",		value_field = "start_tc",		value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field], true) end },
						{ name = "End TC",			value_field = "end_tc",			value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field], true) end },
						{ name = "Duration (TC)",	value_field = "duration_tc",	value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field], true) end },
						{ name = "Duration (Time)",	value_field = "duration_time",	value = function(self, marker_data) return marker_data[self.value_field] end },
						{ name = "Color",			value_field = "color",			value = function(self, marker_data) return marker_data[self.value_field] end },
						{ name = "Note",			value_field = "note",			value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field]) end }
					),
					separator = "\t",
				},
			},

			premiere_csv = 
			{	-- Adobe calls it csv even though its tab-delimited
				name = "Premiere Pro CSV",
				extension = "csv",
				export_config =
				{
					fields = table.pack
					(
						{ name = "Marker Name",		value_field = "name",			value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field]) end },
						{ name = "Description",		value_field = "note",			value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field]) end },
						{ name = "In",				value_field = "start_tc",		value = function(self, marker_data) return marker_data[self.value_field] end },
						{ name = "Out",				value_field = "end_tc",			value = function(self, marker_data) return marker_data[self.value_field] end },
						{ name = "Duration",		value_field = "duration_tc",	value = function(self, marker_data) return marker_data[self.value_field] end },
						{ name = "Marker Type",		value_field = nil,				value = function(self, marker_data) return "Comment" end }
					),
					separator = "\t",
				},
			},

			json =
			{
				name = "JSON Data",
				extension = "json",
			},

			youtube =
			{
				name = "YouTube Chapters",
				extension = "txt",
				always_start_at_zero = true,
			},

			fairlight =
			{	-- Note: Fairlight can't import ADR Cues with timecode that has three digits for frames (frame rates above 100fps)
				name = "Fairlight ADR Cues",
				extension = "csv",
				export_config =
				{
					fields = table.pack
					(
						{ name = "Cue ID",			value_field = "index",			value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field], true) end },
						{ name = "In Point",		value_field = "start_tc",		value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field], true) end },
						{ name = "Out Point",		value_field = "end_tc",			value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field], true) end },
						{ name = "Character",		value_field = "name",			value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field], true) end },
						{ name = "Dialog",			value_field = "note",			value = function(self, marker_data) return stringex.quote_if_needed(marker_data[self.value_field]:gsub("\n", "<br>"), true) end },
						{ name = "Done",			value_field = nil,				value = function(self, marker_data) return stringex.quote_if_needed("False", true) end }
					),
					separator = ",",
					hide_header = true,
				},
			},

			srt =
			{
				name = "SRT Subtitles",
				extension = "srt",
			},

			webvtt =
			{
				name = "WebVTT Subtitles",
				extension = "vtt",
			},

			sort_order = { "fairlight", "json", "premiere_csv", "srt", "tab_delimited_text", "webvtt", "youtube" },
		},
	},
}

libavutil = 
{
	library = luaresolve.load_library(iif(ffi.os == "Windows", "avutil*.dll", iif(ffi.os == "OSX", "libavutil*.dylib", "libavutil.so"))),

	demand_version = function(self, version)
		local library_version = self:av_version_info()

		return (library_version.major > version.major)
			or (library_version.major == version.major and library_version.minor > version.minor)
			or (library_version.major == version.major and library_version.minor == version.minor and library_version.patch > version.patch)
			or (library_version.major == version.major and library_version.minor == version.minor and library_version.patch == version.patch)
	end,

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

			char* av_version_info (void);
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

		if (flags.AV_TIMECODE_FLAG_DROPFRAME and fps > 60 and (fps % (30000 / 1001) == 0 or fps % 29.97 == 0))
			and (not self:demand_version( { major = 4, minor = 4, patch = 0 } ))
		then
			-- Adjust for drop frame above 60 fps (not necessary if BMD upgrades to libavutil-57 or later)
			frame = frame + 9 * tc.fps / 15 * (math.floor(frame / (tc.fps * 599.4))) + (math.floor((frame % (tc.fps * 599.4)) / (tc.fps * 59.94))) * tc.fps / 15
		end

		local timecodestring = ffi.string(self.library.av_timecode_make_string(tc, ffi.string(string.rep(" ", 16)), frame))
	
		if (#timecodestring > 0) then
			local frame_digits = #tostring(math.ceil(fps) - 1)

			-- Fix for libavutil where it doesn't use leading zeros for timecode at frame rates above 100
			if frame_digits > 2 then
				timecodestring = string.format("%s%0"..frame_digits.."d", timecodestring:sub(1, timecodestring:find("[:;]%d+$")), tonumber(timecodestring:match("%d+$")))
			end

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
	end,

	av_version_info = function(self)
		local version = ffi.string(self.library.av_version_info())

		return 
		{
			major = tonumber(version:match("^%d+")),
			minor = tonumber(version:match("%.%d+"):sub(2)),
			patch = tonumber(version:match("%d+$"))
		}
	end,
}

script.set_declarations()
script:load_settings()

local function create_window(timeline, frame_rate, drop_frame)
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

		FixedSize = { 800, 400 },
		
		ui:VGroup
		{
			Weight = 1,
			Spacing = 10,

			ui:Tree
			{
				Weight = 1,
				ID = "MarkersTreeView", 
				AlternatingRowColors = true,
				RootIsDecorated = false,
				SortingEnabled = true,
				Events = { ItemDoubleClicked = true },
			},

			ui:HGroup
			{
				Weight = 0,

				ui:HGroup
				{
					Weight = 0,
					Spacing = 10,
				
					ui:Label
					{
						Weight = 0,
						Alignment = { AlignRight = true, AlignVCenter = true },
						MinimumSize = 80,
						MaximumSize = 80,
						Text = "Format",
					},
				
					ui:ComboBox
					{
						Weight = 1,
						ID = "FormatComboBox",
						FocusPolicy = { StrongFocus = true },
						StyleSheet = [[
							QComboBox
							{
								margin-top: 3px;
								padding-right: 6px;
								padding-left: 6px;
								min-height: 18px;
								max-height: 18px;
							}
						]],
					},

					ui:HGap(10),
				},

				ui:HGroup
				{
					Weight = 0,
					ID = "CheckBoxControls",
					Spacing = 10,
				
					ui:CheckBox
					{
						Weight = 0,
						ID = "ForceZeroCheckBox",
						Text = "Force start at zero",
						Events = { Toggled = true },
						Checked = script.settings.force_start_at_zero,
						ToolTip = "Override the timeline start timecode and export as if it started at zero.",
					},

					ui:HGap(10),
				},

				ui:HGroup
				{
					Weight = 1,
					Spacing = 10,
				
					ui:Label
					{
						Weight = 0,
						Alignment = { AlignRight = true, AlignVCenter = true },
						MinimumSize = 80,
						MaximumSize = 80,
						Text = "Color",
					},
				
					ui:ComboBox
					{
						Weight = 0,
						ID = "ColorComboBox",
						FocusPolicy = { StrongFocus = true },
						StyleSheet = [[
							QComboBox
							{
								margin-top: 3px;
								padding-right: 6px;
								padding-left: 6px;
								min-height: 18px;
								max-height: 18px;
							}
						]],
					},
				},

				ui:HGap(0, 1),

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
						ID = "ExportButton",
						Text = "Export",
						AutoDefault = false,
						Default = true,
					},
				},
			},
		},
	})

	window_items = window:GetItems()

	local start_frame = timeline:GetStartFrame()

	-- All markers
	local markers = {}

	-- A table that will contain ordered marker frames
	local marker_frames = {}

	-- A marker table we will use for processing
	local marker_table = {}

	local marker_count_by_color = {}

	local function update_controls()
		local marker_count = marker_count_by_color[window_items.ColorComboBox.CurrentText]
		window_items.ExportButton.Enabled = marker_count ~= nil and marker_count > 0

		local selected_format = luaresolve.markers.formats.sort_order[window_items.FormatComboBox.CurrentIndex + 1]
		window_items.CheckBoxControls.Hidden = start_frame == 0 or luaresolve.markers.formats[selected_format].always_start_at_zero == true

		-- Clear marker_table and the tree
		marker_table = {}
		window_items.MarkersTreeView.UpdatesEnabled = false
		window_items.MarkersTreeView:Clear()

		local timeline_start = iif(window_items.ForceZeroCheckBox.Checked or window_items.CheckBoxControls.Hidden, 0, start_frame)
		local count = 0

		for _, frame in ipairs(marker_frames) do
			local marker = markers[frame]

			if window_items.ColorComboBox.CurrentText == "Any" or window_items.ColorComboBox.CurrentText == marker.color then
				count = count + 1
				
				local item = window_items.MarkersTreeView:NewItem()

				local data = 
				{
					index = count,
					frame = timeline_start + frame,
					name = marker.name,
					start_tc = luaresolve:timecode_from_frame(timeline_start + frame, frame_rate, drop_frame),
					end_tc = luaresolve:timecode_from_frame(timeline_start + frame + marker.duration, frame_rate, drop_frame),
					duration_tc = luaresolve:timecode_from_frame(marker.duration, frame_rate, drop_frame),
					duration_time = luaresolve:time_from_frame(marker.duration, frame_rate).time,
					duration_frames = marker.duration,
					color = marker.color,
					note = marker.note,
					custom_data = marker.customData,
				}

				 -- We're using SetData instead of Text so we can get the natural sort order of numbers
				item:SetData(0, "DisplayRole", count)
				item:SetData(1, "DisplayRole", data.frame)
				item:SetData(2, "DisplayRole", data.name)
				item:SetData(3, "DisplayRole", data.start_tc)
				item:SetData(4, "DisplayRole", data.end_tc)
				item:SetData(5, "DisplayRole", data.duration_tc)
				item:SetData(6, "DisplayRole", data.duration_time)
				item:SetData(7, "DisplayRole", data.color)
				item:SetData(8, "DisplayRole", data.note:gsub("\n", " "))

				-- Change the text color when using a fractional frame rate
				if frame_rate % 1 > 0 then
					item.TextColor[6] = { R = 0.831, G = 0.678, B = 0.122, A = 1 }
				end

				window_items.MarkersTreeView:AddTopLevelItem(item)
				marker_table[#marker_table+1] = data
			end
		end

		window_items.MarkersTreeView:SetHeaderLabels( { "#", "Frame", "Name", "Start TC", "End TC", "Duration (TC)", "Duration (Time)", "Color", "Notes" } )
		window_items.MarkersTreeView:SortByColumn(0, "AscendingOrder")
		window_items.MarkersTreeView.UpdatesEnabled = true

		window:RecalcLayout()
	end

	local function initialize_controls()
		for _, format in ipairs(luaresolve.markers.formats.sort_order) do
			window_items.FormatComboBox:AddItem(string.format("%s (*.%s)", luaresolve.markers.formats[format].name, luaresolve.markers.formats[format].extension))
		end

		window_items.ColorComboBox:AddItem("Any")
		window_items.ColorComboBox:AddItems(luaresolve.markers.colors)
		window_items.ColorComboBox:InsertSeparator(1)

		window_items.MarkersTreeView.ColumnCount = 9
		window_items.MarkersTreeView.ColumnWidth[0] = 35
		window_items.MarkersTreeView.ColumnWidth[1] = 70
		window_items.MarkersTreeView.ColumnWidth[2] = 100
		window_items.MarkersTreeView.ColumnWidth[3] = 80
		window_items.MarkersTreeView.ColumnWidth[4] = 80
		window_items.MarkersTreeView.ColumnWidth[5] = 80
		window_items.MarkersTreeView.ColumnWidth[6] = 95
		window_items.MarkersTreeView.ColumnWidth[7] = 60

		markers = timeline:GetMarkers()
		marker_count_by_color = luaresolve.markers.get_marker_count_by_color(markers)

		-- Add marker frames to the marker_frames table
		for marker_frame, _ in pairs(markers) do
			marker_frames[#marker_frames+1] = marker_frame
		end
			
		-- Sort the table
		table.sort(marker_frames)

		-- Set controls to values loaded from settings
		window_items.FormatComboBox.CurrentText = string.format("%s (*.%s)", luaresolve.markers.formats[script.settings.format].name, luaresolve.markers.formats[script.settings.format].extension)

		if marker_count_by_color[script.settings.color] then
			window_items.ColorComboBox.CurrentText = script.settings.color
		else
			window_items.ColorComboBox.CurrentText = "Any"
		end

		update_controls()
	end

	initialize_controls()

	window.On.FormatComboBox.CurrentIndexChanged = function(ev)
		update_controls()
	end

	window.On.ForceZeroCheckBox.Toggled = function(ev)
		update_controls()
	end

	window.On.ColorComboBox.CurrentIndexChanged = function(ev)
		update_controls()
	end

	window.On.MarkersTreeView.ItemDoubleClicked = function(ev)
		-- Exit the UI loop and return the action we want to perform
		dispatcher:ExitLoop
		{
			action = "gotomarker",
			frame = ev.item:GetData(1, "DisplayRole") + iif(window_items.ForceZeroCheckBox.Checked or window_items.CheckBoxControls.Hidden, start_frame, 0)
		}
	end

	window.On.ExportButton.Clicked = function(ev)
		local format = luaresolve.markers.formats.sort_order[window_items.FormatComboBox.CurrentIndex + 1]
		local filter = string.format("%s (*.%s)|*.%s", luaresolve.markers.formats[format].name, luaresolve.markers.formats[format].extension, luaresolve.markers.formats[format].extension)

		-- Note: While it's possible to put all the formats in the "Save as type" dropdown in the Request window opened by RequestFile, it's *not* possible to set the correct default
		-- type with FReqS_DefExtension if extensions aren't unique. There's also no way of knowing which type the user selected as all we get back is a filename.
		-- That's the reason we force the user to set the file format in the form first.

		local filename = fusion:RequestFile(script.settings.folder, timeline:GetName(), { FReqB_Saving = true, FReqS_Filter = filter } )

		if filename then
			script.settings.format = format
			script.settings.force_start_at_zero = window_items.ForceZeroCheckBox.Checked
			script.settings.color = window_items.ColorComboBox.CurrentText
			script.settings.folder = ( { splitpath(filename) } )[1]
			script:save_settings()
		
			-- Exit the UI loop and return the action we want to perform
			dispatcher:ExitLoop
			{
				action = "export",
				marker_table = marker_table,
				filename = filename,
			}
		end
	end

	window.On.CancelButton.Clicked = function(ev)
		-- Exit the UI loop without returning anything
		dispatcher:ExitLoop()
	end

	window.On[script.window_id].Close = function(ev)
		window_items.CancelButton:Click()
	end

	return window, window_items
end

local function main()
	local project = assert(resolve:GetProjectManager():GetCurrentProject(), "Couldn't get current project")
	local timeline = assert(project:GetCurrentTimeline(), "Couldn't get current timeline")
	local frame_rate = luaresolve.frame_rates:get_decimal(timeline:GetSetting("timelineFrameRate"))
	local drop_frame = timeline:GetSetting("timelineDropFrameTimecode") == "1"
	local window, window_items = create_window(timeline, frame_rate, drop_frame)

	window:Show()
	
	-- Run the UI loop where it will wait for events
	local return_value = script.dispatcher:RunLoop()

	window:Hide()

	if return_value then
		if return_value.action == "gotomarker" then
			timeline:SetCurrentTimecode(luaresolve:timecode_from_frame(return_value.frame, frame_rate, drop_frame))
		elseif return_value.action == "export" then
			local function write_file(filename, content)
				local file_handle = assert(io.open(filename, "w+"))
				assert(file_handle:write(content))
				assert(file_handle:close())
			end

			local function export(marker_table, config, filename)
				local export_content = {}

				if not config.hide_header then
					local header = {}

					for _, export_field in ipairs(config.fields) do
						header[#header+1] = export_field.name
					end
				
					export_content[#export_content+1] = table.concat(header, config.separator)
				end

				for _, marker_data in ipairs(marker_table) do
					local row = {}

					for _, export_field in ipairs(config.fields) do
						row[#row+1] = export_field:value(marker_data)
					end

					export_content[#export_content+1] = table.concat(row, config.separator)
				end

				write_file(filename, table.concat(export_content, "\n"))
			end

			local function export_json(marker_table, filename)
				local json = require ("dkjson")
				write_file(filename, json.encode(marker_table, { indent = true }))
			end

			local function export_youtube_chapters(marker_table, filename)
				local show_hours = luaresolve:time_from_frame(marker_table[#marker_table].frame, frame_rate).hours > 0
				local has_first_chapter = false
				local chapters = {}
					
				for index, marker_data in ipairs(marker_table) do
					local time_info = luaresolve:time_from_frame(marker_data.frame, frame_rate)

					if not has_first_chapter then
						if time_info.total_milliseconds > 0 then
							-- If there's no marker at the start of the timeline we add a chapter
							chapters[#chapters+1] = iif(show_hours, "00:00:00", "00:00").." Start"
						end

						has_first_chapter = true
					end

					if show_hours then
						chapters[#chapters+1] = string.format("%02d:%02d:%02d %s", time_info.hours, time_info.minutes, time_info.seconds, marker_data.name)
					else
						chapters[#chapters+1] = string.format("%02d:%02d %s", time_info.minutes, time_info.seconds, marker_data.name)
					end
				end

				write_file(filename, table.concat(chapters, "\n"))
			end

			local function export_subtitles(marker_table, format, filename)
				local subtitles = {}

				if format == "webvtt" then
					subtitles[#subtitles+1] = "WEBVTT\n"
				end

				for index, marker_data in ipairs(marker_table) do
					local start_time = luaresolve:time_from_frame(marker_data.frame, frame_rate).time
					local end_time = luaresolve:time_from_frame(marker_data.frame + marker_data.duration_frames, frame_rate).time

					if format == "srt" then
						start_time = start_time:gsub("%.", ",")
						end_time = end_time:gsub("%.", ",")
					end

					subtitles[#subtitles+1] = string.format("%s\n%s --> %s\n%s\n", index, start_time, end_time, marker_data.note)
				end

				write_file(filename, table.concat(subtitles, "\n"))
			end

			local export_format = luaresolve.markers.formats[script.settings.format]

			if export_format then
				if script.settings.format == "json" then
					export_json(return_value.marker_table, return_value.filename)
				elseif script.settings.format == "youtube" then
					export_youtube_chapters(return_value.marker_table, return_value.filename)
				elseif script.settings.format == "srt" or script.settings.format == "webvtt" then
					export_subtitles(return_value.marker_table, script.settings.format, return_value.filename)
				else
					export(return_value.marker_table, export_format.export_config, return_value.filename)
				end
			else
				error("Unknown marker export format: "..script.settings.format)
			end
		end
	end
end

main()
