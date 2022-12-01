local script, luaresolve, libavutil

script =
{
	filename = debug.getinfo(1,"S").source:match("^.*%@(.*)"),
	name = "Render Clips by Guide Track",
	version = "1.0",
	default_timeout = 30, -- seconds

	settings =
	{
		render_preset = nil,
		clear_completed = true,
		location = nil,
		filename_from = nil,
		custom_filename = "Clip %{ClipNumber}",
		timecode_from = nil,
		custom_timecode = nil,
		last_timeline_id = nil,
		guide_track = nil,
		guide_track_type = nil,
		stop_on_error = false,
	},

	constants =
	{
		RENDER_PRESET = 
		{
			CURRENT_SETTINGS = "Current settings",
		},

		FILENAME_FROM = 
		{
			GUIDE_TRACK_CLIP_FILENAME = "Guide track clip filename",
			GUIDE_TRACK_CLIP_NAME = "Guide track clip name (trimmed file extension)",
			GUIDE_TRACK_CLIP_NAME_FILTERED = "Guide track clip name (filtered file extension)",
			CUSTOM = "Custom",
		},

		TIMECODE_FROM = 
		{
			GUIDE_TRACK_CLIP = "Guide track clip",
			TIMELINE = "Timeline",
			CUSTOM = "Custom",
		},

		VARIABLES =
		{
			CLIP_FILENAME = "%{ClipFilename}",
			CLIP_NAME = "%{ClipName}",
			CLIP_NAME_FILTERED = "%{ClipNameFiltered}",
			CLIP_NUMBER = "%{ClipNumber}",
			CURRENT_DATE = "%{CurrentDate}",
			CURRENT_TIME = "%{CurrentTime}",
			TRACK_NAME = "%{TrackName}",
			TRACK_NUMBER = "%{TrackNumber}",
			TRACK_TYPE = "%{TrackType}",
		},
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

	window_id = "RenderClips",

	set_declarations = function()
		ffi.cdef[[ void Sleep(int ms); int poll(struct pollfd *fds, unsigned long nfds, int timeout); ]]
		libavutil.set_declarations()
	end,

	sleep = iif(ffi.os == "Windows", function(milliseconds) ffi.C.Sleep(milliseconds) end, function(milliseconds) ffi.C.poll(nil,0,milliseconds) end),

	retry = function(self, settings)
		local result = settings.func(table.unpack(settings.arguments))
		local success = result ~= nil and result ~= false
		local start_time = os.clock()
		local timeout = iif(settings.timeout, settings.timeout, self.default_timeout)

		-- Make the secondary progress bar visible
		if not success and settings.window then
			script:update_progress(settings.window, "SecondaryProgressUpdated", { Progress = 100, Status = string.format("Retrying command... (%ss)", timeout), Visible = true } )
		end

		while (not success) do
			local elapsed_time = os.clock() - start_time
			local time_left = timeout - elapsed_time

			if (elapsed_time >= timeout) then

				--TODO: should we have a settings.continue_after_fail bool? Now we're closing the window even if we want to continue. 

				if settings.window then
					-- Progress window
					self.dispatcher:ExitLoop()
					settings.window:Hide()
				end

				self:show_popup( { 500, 200 }, settings.message, { "OK" } )
				
				return result
			end

			if settings.window then
				script:update_progress(settings.window, "SecondaryProgressUpdated", { Progress = 100 * time_left / timeout, Status = string.format("Retrying command... (%.0fs)", time_left) } )
			end

			self.sleep(500)

			result = settings.func(table.unpack(settings.arguments))
			success = result ~= nil and result ~= false

			-- Hide the secondary progress bar
			if success and settings.window then
				script:update_progress(settings.window, "SecondaryProgressUpdated", { Progress = 0, Status = "", Visible = false } )
			end
		end

		return result
	end,

	show_popup = function(self, size, text, buttons, modality)
		local popup_window_id = self.window_id.."PopUp"
		local window_modality = iif(modality ~= nil, modality, "None")

		local popup_window = self.dispatcher:AddWindow(
		{
			ID = popup_window_id,
			WindowTitle = self.name,
			WindowFlags =
			{
				Dialog = true,
				WindowTitleHint = true,
				WindowCloseButtonHint = true,
			},

			WindowModality = window_modality,

			Events = 
			{
				Close = true,
				KeyPress = true,
			},

			FixedSize =
			{
				iif(size and #size == 2, size[1], 570),
				iif(size and #size == 2, size[2], 260),
			},

			self.ui:VGroup
			{
				MinimumSize = { 200, 150 },
				MaximumSize = { 16777215, 16777215 },

				self.ui:TextEdit
				{
					Weight = 1,
					Text = text,
					ReadOnly = true,
					TextFormat = { RichText = true },
					TextInteractionFlags = { NoTextInteraction = true },
					FocusPolicy = { NoFocus = true },
					StyleSheet = [[
						QTextEdit
						{
							border: none;
						}
					]],
				},

				self.ui:HGroup
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

					self.ui:HGap(0, 1),

					self.ui:HGroup
					{
						Weight = 0,
						ID = "ButtonsGroup",
					},
				},
			},
		})

		local popup_items = popup_window:GetItems()
		
		-- Add buttons and events
		for index, button in ipairs(buttons) do
			popup_items.ButtonsGroup:AddChild(self.ui:Button
			{
				ID = popup_window_id..button,
				Text = button,
				Default = index == #buttons,
			})

			popup_window.On[popup_window_id..button].Clicked = function(ev)
				self.dispatcher:ExitLoop(button:lower())
			end
		end

		popup_window:Find(popup_window_id..buttons[#buttons]):SetFocus()

		popup_window.On[popup_window_id].KeyPress = function(ev)
			if (ev.Key == 16777216) then -- Escape
				self.dispatcher:ExitLoop("escape")
			end
		end

		popup_window.On[popup_window_id].Close = function(ev)
			self.dispatcher:ExitLoop("closewindow")
		end
		
		popup_window:Show()
		local value = self.dispatcher:RunLoop()
		popup_window:Hide()

		return value
	end,

	create_progress_window = function(self, header)
		local width = 400
		local height = 154
		local progress_y_pos = 60
		local progress_margin = 67
		local progress_bottom_margin = 30

		local progress_window = self.dispatcher:AddWindow(
		{
			ID = script.window_id.."Progress",
			Margin = 0,
			Spacing = 0,
			WindowFlags =
			{
				SplashScreen = true
			},

			Events =
			{
				ProgressUpdated = true,
				SecondaryProgressUpdated = true,
				HeaderUpdated = true,
				SecondaryHeaderUpdated = true,
			},

			FixedSize = { width, height },

			self.ui:Label
			{
				ID = "ProgressWindowBorder",
				StyleSheet = [[
					QLabel
					{
						min-width: ]]..(width - 2)..[[px;
						min-height: ]]..(height - 2)..[[px;
						max-width: ]]..(width - 2)..[[px;
						max-height: ]]..(height - 2)..[[px;

						border: 1px solid rgb(7, 7, 7);
					}
				]],
			},

			self.ui:Label
			{
				ID = "ProgressHeaderBackground",
				StyleSheet = [[
					QLabel
					{
						min-width: ]]..(width - 2)..[[px;
						min-height: 28px;
						max-width: ]]..(width - 2)..[[px;
						max-height: 28px;
			
						margin: 1px 1px 0px 1px;
			
						background-color: rgb(36, 36, 36);
							
						border-bottom: 1px solid rgb(9, 9, 9);
					}
				]],
			},

			self.ui:Label
			{
				ID = "ProgressHeader",
				Text = header,
				StyleSheet = [[
					QLabel
					{
						min-width: ]]..(width - 22)..[[px;
						max-width: ]]..(width - 22)..[[px;
			
						margin: 6px 10px 0px 10px;

						color: white;
					}
				]],
			},

			self.ui:Label
			{
				Weight = 1,
				ID = "SecondaryProgressHeader",
				Alignment = { AlignRight = true },
				StyleSheet = [[
					QLabel
					{
						min-width: ]]..(width - 22)..[[px;
						max-width: ]]..(width - 22)..[[px;
			
						margin: 6px 10px 0px 10px;

						color: rgb(221, 32, 48);
					}
				]],
			},

			self.ui:Label
			{
				ID = "ProgressBarStatus",
				StyleSheet = [[
					QLabel
					{
						min-width: ]]..(width - progress_margin + 4)..[[px;
						max-width: ]]..(width - progress_margin + 4)..[[px;
			
						color: white;
					}
				]],
			},

			self.ui:Label
			{
				ID = "ProgressBarBorder",
				StyleSheet = [[
					QLabel
					{
						min-width: ]]..(width - progress_margin)..[[px;
						min-height: 1px;
						max-width: ]]..(width - progress_margin)..[[px;
						max-height: 1px;

						background-color: rgb(37, 37, 37);
						border: 1px solid rgb(23, 23, 23);
					}
				]],
			},

			self.ui:Label
			{
				ID = "ProgressBar",
				StyleSheet = [[
					QLabel
					{
						min-width: 0px;
						min-height: 1px;
						max-width: ]]..(width - progress_margin)..[[px;
						max-height: 1px;

						background-color: rgb(102, 221, 39);
					}
				]],
			},

			self.ui:Label
			{
				ID = "SecondaryProgressBarStatus",
				Visible = false,
				StyleSheet = [[
					QLabel
					{
						min-width: ]]..(width - progress_margin + 4)..[[px;
						max-width: ]]..(width - progress_margin + 4)..[[px;
			
						color: rgb(240, 132, 132);
					}
				]],
			},

			self.ui:Label
			{
				ID = "SecondaryProgressBarBorder",
				Visible = false,
				StyleSheet = [[
					QLabel
					{
						min-width: ]]..(width - progress_margin)..[[px;
						min-height: 1px;
						max-width: ]]..(width - progress_margin)..[[px;
						max-height: 1px;

						background-color: rgb(37, 37, 37);
						border: 1px solid rgb(23, 23, 23);
					}
				]],
			},

			self.ui:Label
			{
				ID = "SecondaryProgressBar",
				Visible = false,
				StyleSheet = [[
					QLabel
					{
						min-width: 0px;
						min-height: 1px;
						max-width: ]]..(width - progress_margin)..[[px;
						max-height: 1px;

						background-color: rgb(240, 132, 132);
					}
				]],
			},
		})

		local progress_items = progress_window:GetItems()

		progress_items.ProgressBar:Resize( { 0, 1} )
		progress_items.SecondaryProgressBar:Resize( { 0, 1} )

		progress_items.ProgressWindowBorder:Lower()
		progress_items.ProgressBar:Lower()
		progress_items.SecondaryProgressBar:Lower()
		progress_items.ProgressBarBorder:Lower()
		progress_items.SecondaryProgressBarBorder:Lower()
		progress_items.ProgressBarStatus:Lower()
		progress_items.SecondaryProgressBarStatus:Lower()

		progress_items.ProgressBarBorder:Move( { (progress_margin - 1) / 2, progress_y_pos + 18 } )
		progress_items.ProgressBar:Move( { (progress_margin + 1) / 2, progress_y_pos + 19 } )
		progress_items.ProgressBarStatus:Move( { (progress_margin - 1) / 2 - 1, progress_y_pos } )

		progress_items.SecondaryProgressBarBorder:Move( { (progress_margin - 1) / 2, progress_y_pos + 18 + progress_bottom_margin } )
		progress_items.SecondaryProgressBar:Move( { (progress_margin + 1) / 2, progress_y_pos + 19 + progress_bottom_margin } )
		progress_items.SecondaryProgressBarStatus:Move( { (progress_margin - 1) / 2 - 1, progress_y_pos + progress_bottom_margin } )

		progress_window.On[script.window_id.."Progress"].ProgressUpdated = function(ev)
			progress_items.ProgressBarStatus.Text = ev.Status
			progress_items.ProgressBar:Resize( { ev.Progress * (width - progress_margin) / 100, 1} )
		end
	
		progress_window.On[script.window_id.."Progress"].SecondaryProgressUpdated = function(ev)
			if ev.Visible ~= nil then
				progress_items.SecondaryProgressBarStatus.Visible = ev.Visible
				progress_items.SecondaryProgressBarBorder.Visible = ev.Visible
				progress_items.SecondaryProgressBar.Visible = ev.Visible
			end

			progress_items.SecondaryProgressBarStatus.Text = ev.Status
			progress_items.SecondaryProgressBar:Resize( { ev.Progress * (width - progress_margin) / 100, 1} )
		end
		
		progress_window.On[script.window_id.."Progress"].HeaderUpdated = function(ev)
			progress_items.ProgressHeader.Text = ev.Status
		end

		progress_window.On[script.window_id.."Progress"].SecondaryHeaderUpdated = function(ev)
			progress_items.SecondaryProgressHeader.Text = ev.Status
		end

		return progress_window._window
	end,

	update_progress = function(self, control, event_name, event_data)
		self.ui:QueueEvent(control, event_name, event_data)
		self.dispatcher:StepLoop()
	end,

	iso_date = function()
	    local date_time = os.date("*t")
		return string.format("%04d-%02d-%02d", date_time.year, date_time.month, date_time.day)
	end,

	iso_time = function()
	    local date_time = os.date("*t")
		return string.format("%02d:%02d:%02d", date_time.hour, date_time.min, date_time.sec)
	end,

	iso_date_time = function()
		local date_time = os.date("*t")
		return string.format("%04d-%02d-%02d %02d:%02d:%02d", date_time.year, date_time.month, date_time.day, date_time.hour, date_time.min, date_time.sec)
	end,

	io =
	{
		test_write_permissions = function(self, path)
			if path == nil or #path == 0 then
				return false, "Invalid path"
			else
				local folder_path = self.ensure_separator(path)

				if bmd.fileexists(folder_path) then
					local test_folder_path = string.format("%s%s", folder_path, bmd.createuuid())

					if bmd.createdir(test_folder_path) then
						bmd.removedir(test_folder_path)
						return true, nil
					else
						return false, "Write permission denied"
					end
				else
					return false, "Path not found"
				end
			end
		end,

		ensure_separator = function(path)
			if path == nil then
				return nil
			else
				local last_character = path:sub(-1)
				return string.format("%s%s", path, iif(last_character == "\\" or last_character == "/", "", package.config:sub(1, 1)))
			end
		end
	},

	ui = app.UIManager,
	dispatcher = bmd.UIDispatcher(app.UIManager)
}

luaresolve = 
{
	frame_rates =
	{
		[16] = { num = 1600, den = 100, },
		[18] = { num = 1800, den = 100 },
		[23.976] = { num = 24000, den = 1001 },
		[24] = { num = 2400, den = 100 },
		[25] = { num = 2500, den = 100 },
		[29.97] = { num = 30000, den = 1001 },
		[30] = { num = 3000, den = 100 },
		[47.952] = { num = 48000, den = 1001 },
		[48] = { num = 4800, den = 100 },
		[50] = { num = 5000, den = 100 },
		[59.94] = { num = 60000, den = 1001 },
		[60] = { num = 6000, den = 100 },
		[72] = { num = 7200, den = 100 },
		[95.904] = { num = 96000, den = 1001 },
		[96] = { num = 9600, den = 100 },
		[100] = { num = 10000, den = 100 },
		[119.88] = { num = 120000, den = 1001 },
		[120] = { num = 12000, den = 100 },

		get_fraction = function(self, frame_rate_value)
			if (type(frame_rate_value) == "string") then
				frame_rate_value = tonumber(frame_rate_value)
			end
		
			if (self[frame_rate_value] == nil) then
				-- Workaround for missing decimals in the timelineFrameRate setting in Resolve on Windows
				-- when the timeline was created while Windows was set to another regional format
				if ((frame_rate_value + 1) % 24 == 0) then
					local factor = (frame_rate_value + 1) / 24 
				
					return
					{
						num = 24000 * factor,
						den = 1001
					}
				elseif ((frame_rate_value + 1) % 30 == 0) then
					local factor = (frame_rate_value + 1) / 30 
				
					return
					{
						num = 30000 * factor,
						den = 1001
					}
				else
					error(string.format("%s is not a supported frame rate", frame_rate_value))
				end    
			else
				return self[frame_rate_value]
			end
		end,

		get_decimal = function(self, frame_rate_value)
			local fraction = self:get_fraction(frame_rate_value)
			return tonumber(string.format("%.2f", fraction.num / fraction.den))
		end
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
			AV_TIMECODE_FLAG_DROPFRAME = drop_frame,
			AV_TIMECODE_FLAG_24HOURSMAX = true,
			AV_TIMECODE_FLAG_ALLOWNEGATIVE = false
		})
	end,

	get_tracks_by_type = function(timeline, ignore_empty_tracks)
		local track_names_by_type = { audio = {}, video = {}, subtitle = {} }

		for track_type, track_names in pairs(track_names_by_type) do
			for i = 1, timeline:GetTrackCount(track_type) do
				if not ignore_empty_tracks or (ignore_empty_tracks == true and #timeline:GetItemListInTrack(track_type, i) > 0) then
					track_names[#track_names+1] =
					{
						index = i,
						name = timeline:GetTrackName(track_type, i)
					}
				end
			end
		end

		return track_names_by_type
	end,

	change_page = function(page)
		local current_page, state

		current_page = resolve:GetCurrentPage()
		
		local function get_state()
			local current_state =
			{
				page = current_page,
				project = resolve:GetProjectManager():GetCurrentProject()
			}

			if current_state.project then
				current_state.timeline = current_state.project:GetCurrentTimeline()

				if current_state.timeline then
					current_state.timecode = current_state.timeline:GetCurrentTimecode()
				end
			end

			return current_state
		end

		if current_page == "media" or current_page == "fusion" then
			-- We can't get current timecode from the Media or Fusion pages, so try switching to the requested page first
			assert(resolve:OpenPage(page), "Couldn't open page: "..page)
			state = get_state()
		else
			-- Otherwise get the state first, in case we're switching to Media or Fusion
			state = get_state()
			assert(resolve:OpenPage(page), "Couldn't open page: "..page)
		end

		return state
	end,

	restore_page = function(state)
		local function set_state(initial_state)
			local current_project, current_timeline
			current_project = resolve:GetProjectManager():GetCurrentProject()

			if current_project then
				current_timeline = current_project:GetCurrentTimeline()

				if current_timeline ~= nil and current_timeline == initial_state.timeline and initial_state.timecode ~= nil then
					initial_state.timeline:SetCurrentTimecode(initial_state.timecode)
				end
			end
		end

		local current_page = resolve:GetCurrentPage()

		if current_page == "media" or current_page == "fusion" then
			-- We can't get set current timecode on the Media or Fusion pages, so try switching to the original page first
			resolve:OpenPage(state.page)
			set_state(state)
		else
			-- Otherwise set the state first, in case we're going back to Media or Fusion
			set_state(state)
			resolve:OpenPage(state.page)
		end
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
script:load_settings()

local function create_window(project, timeline)
	local ui = script.ui
	local dispatcher = script.dispatcher

	local left_column_width = 110
	local right_column_width = 70

	local left_column_minimum_size = { left_column_width, 0 }
	local left_column_maximum_size = { left_column_width, 16777215 }
	local right_column_minimum_size = { right_column_width + 2, 0 }
	local right_column_maximum_size = { right_column_width + 2, 16777215 }

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

		FixedSize = { 570, 260 },

		StyleSheet = [[
			QComboBox
			{
				padding-right: 10px;
				padding-left: 10px;
				min-height: 18px;
				max-height: 18px;
				color: rgb(146, 146, 146);
			}

			QComboBox:on
			{
				color: white;
			}

			QLineEdit
			{
				padding-top: 0px;
				margin-top: 1px;
				min-height: 18px;
				max-height: 18px;
				color: rgb(146, 146, 146);
			}

			QLineEdit:focus
			{
				color: white;
			}

			QPushButton
			{
				min-height: 20px;
				max-height: 20px;
				min-width: ]]..right_column_width..[[px;
				max-width: ]]..right_column_width..[[px;
			}
		]],

		ui:VGroup
		{
			MinimumSize = { 550, 230 },
			MaximumSize = { 16777215, 16777215 },

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Text = "Render Preset",
					Alignment = { AlignTop = true, AlignRight = true },
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
				},

				ui:ComboBox
				{
					ID = "PresetComboBox",
					FocusPolicy = { StrongFocus = true },
				},

				ui:Label { MinimumSize = right_column_minimum_size, MaximumSize = right_column_maximum_size },
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Text = "Location",
					Alignment = { AlignRight = true },
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
				},

				ui:LineEdit
				{
					Weight = 1,
					ID = "LocationLineEdit",
					Text = "",
				},

				ui:Button
				{
					Weight = 0,
					ID = "LocationButton",
					Text = "Browse",
				},
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Text = "Guide Track",
					Alignment = { AlignRight = true },
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
				},
				
				ui:ComboBox
				{
					ID = "GuideTrackComboBox",
					FocusPolicy = { StrongFocus = true },
				},

				ui:Label { MinimumSize = right_column_minimum_size, MaximumSize = right_column_maximum_size },
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Text = "Filename",
					Alignment = { AlignRight = true },
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
				},
				
				ui:ComboBox
				{
					ID = "FilenameComboBox",
					Events = { CurrentTextChanged = true },
					FocusPolicy = { StrongFocus = true },
					ToolTip =	[[<p><b>]]..script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_FILENAME..[[</b><br />
						If the guide track clip has a filename, it will use that. If not, it will use the clip name.
						The file extension will be trimmed out and replaced with the default for the render settings.</p>

						<p><b>]]..script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_NAME..[[</b><br />
						Use the clip name with the file extension trimmed out.</p>

						<p><b>]]..script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_NAME_FILTERED..[[</b><br />
						Use the clip name but filter out the file extension from anywhere inside the clip name,
						not just at the end. Useful for subclips or clips with text added after the filename.</p>

						<p><b>]]..script.constants.FILENAME_FROM.CUSTOM..[[</b><br />
						Set your own filename, with or without variables.]]
				},

				ui:Label { MinimumSize = right_column_minimum_size, MaximumSize = right_column_maximum_size },
			},

			ui:HGroup
			{
				Weight = 0,
				ID = "CustomFilenameGroup",

				ui:Label
				{
					Text = "Custom Filename",
					Alignment = { AlignRight = true },
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
				},
				
				ui:LineEdit
				{
					ID = "CustomFilenameLineEdit",
					Events = 
					{
						TextChanged = true,
						TextEdited = true,
						EditingFinished = true,
						ReturnPressed = true,
						SelectionChanged = true,
						CursorPositionChanged = true
					},
					Text = script.settings.custom_filename,
					ToolTip =	[[<p>These variables are available:</p>
								<table cellspacing="10">
									<tr><td><b>]]..script.constants.VARIABLES.CLIP_FILENAME..[[</b></td>     <td></td></tr>
									<tr><td><b>]]..script.constants.VARIABLES.CLIP_NAME..[[</b></td>         <td></td></tr>
									<tr><td><b>]]..script.constants.VARIABLES.CLIP_NAME_FILTERED..[[</b></td> <td></td></tr>
									<tr><td><b>]]..script.constants.VARIABLES.CLIP_NUMBER..[[</b></td>       <td></td></tr>
									<tr><td><b>]]..script.constants.VARIABLES.CURRENT_DATE..[[</b></td>      <td>In ISO8601 format</td></tr>
									<tr><td><b>]]..script.constants.VARIABLES.CURRENT_TIME..[[</b></td>      <td>In ISO8601 format</td></tr>
									<tr><td><b>]]..script.constants.VARIABLES.TRACK_NAME..[[</b></td>        <td></td></tr>
									<tr><td><b>]]..script.constants.VARIABLES.TRACK_NUMBER..[[</b></td>      <td></td></tr>
									<tr><td><b>]]..script.constants.VARIABLES.TRACK_TYPE..[[</b></td>        <td></td></tr>
								</table>
					]],
				},

				ui:Label { MinimumSize = right_column_minimum_size, MaximumSize = right_column_maximum_size },
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Text = "Timecode",
					Alignment = { AlignRight = true },
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
				},
				
				ui:ComboBox
				{
					ID = "TimecodeComboBox",
					FocusPolicy = { StrongFocus = true },
					Events = { CurrentTextChanged = true },
					ToolTip =	[[<p><b>]]..script.constants.TIMECODE_FROM.GUIDE_TRACK_CLIP..[[</b><br />
								Rendered clips will use the starting timecode of guide track clips.
								If there is no timecode, clips will use the timeline start timecode.</p>

								<p><b>]]..script.constants.TIMECODE_FROM.TIMELINE..[[</b><br />
								Rendered clips will use the timecode at its timeline position.</p>

								<p><b>]]..script.constants.TIMECODE_FROM.CUSTOM..[[</b><br />
								Rendered clips will start at the specified timecode.]]
				},

				ui:Label { MinimumSize = right_column_minimum_size, MaximumSize = right_column_maximum_size },
			},

			ui:HGroup
			{
				Weight = 0,
				ID = "CustomTimecodeGroup",

				ui:Label
				{
					Text = "Custom Timecode",
					Alignment = { AlignRight = true },
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
				},
				
				ui:LineEdit
				{
					ID = "CustomTimecodeLineEdit",
					Events = 
					{
						TextChanged = true,
						TextEdited = true,
						EditingFinished = true,
						ReturnPressed = true,
						SelectionChanged = true,
						CursorPositionChanged = true
					},
					Text = iif(script.settings.custom_timecode, script.settings.custom_timecode, timeline:GetStartTimecode()),
					InputMask = "99:99:99:99", -- Note: Dropframe timecode with a semicolon doesn't work here because of a bug in Qt (https://bugreports.qt.io/browse/QTBUG-1588)
				},

				ui:Label { MinimumSize = right_column_minimum_size, MaximumSize = right_column_maximum_size },
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label { MinimumSize = left_column_minimum_size, MaximumSize = left_column_maximum_size },
				
				ui:CheckBox
				{
					ID = "ClearRendersCheckBox",
					Text = "Clear completed render jobs",
					Checked = script.settings.clear_completed,
					ToolTip =	[[<p>Render jobs are always cleared when Timecode is set to
								<b>]]..script.constants.TIMECODE_FROM.GUIDE_TRACK_CLIP..[[</b> or
								<b>]]..script.constants.TIMECODE_FROM.CUSTOM..[[</b>
								because jobs in the queue won't contain the timecode adjustment
								and is always locked to the timeline timecode setting.</p>

								<p>Clearing render jobs only affects jobs created by the script.</p>]]
				},

				ui:Label { MinimumSize = right_column_minimum_size, MaximumSize = right_column_maximum_size },
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label { MinimumSize = left_column_minimum_size, MaximumSize = left_column_maximum_size },
				
				ui:CheckBox
				{
					ID = "StopOnErrorCheckBox",
					Text = "Stop on render error",
					ToolTip = "<p>When unchecked, rendering will continue to the next clip unless it is an unrecoverable error.</p>",
					Checked = script.settings.stop_on_error,
				},

				ui:Label { MinimumSize = right_column_minimum_size, MaximumSize = right_column_maximum_size },
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

				ui:HGroup
				{
					ui:HGap(0, 1),

					ui:Button
					{
						ID = "CancelButton",
						Text = "Cancel",
						Weight = 0,
					},
				
					ui:Button
					{
						ID = "RenderButton",
						Text = "Render",
						Weight = 0,
						Default = true,
					},
				},
			},
		},
	})

	windowItems = window:GetItems()

	function get_tracks_combobox_items(track_names_by_type)
		local combobox_items = {}

		for _, track_type in ipairs( { "video", "audio", "subtitle" } ) do
			for _, track_data in ipairs(track_names_by_type[track_type]) do
				combobox_items[#combobox_items+1] = 
				{
					type = track_type,
					name = track_data.name,
					index = track_data.index,
				}
			end

			if #track_names_by_type[track_type] > 0 then
				combobox_items[#combobox_items+1] = 
				{
					type = "separator",
				}
			end
		end

		-- Trim the last item if it's a separator
		if combobox_items[#combobox_items].type == "separator" then
			combobox_items[#combobox_items] = nil
		end

		return combobox_items
	end

	local tracks_by_combobox_index = get_tracks_combobox_items(luaresolve.get_tracks_by_type(timeline, true))

	local function update_controls()
		windowItems.LocationLineEdit.ToolTip = windowItems.LocationLineEdit.Text
		windowItems.RenderButton.Enabled = #windowItems.LocationLineEdit.Text > 0
	end

	local function initialize_controls()
		windowItems.PresetComboBox:AddItem(script.constants.RENDER_PRESET.CURRENT_SETTINGS)
		windowItems.PresetComboBox:AddItems(project:GetRenderPresetList())
		windowItems.PresetComboBox:InsertSeparator(1)
		windowItems.PresetComboBox.CurrentText = script.settings.render_preset

		windowItems.LocationLineEdit.Text = script.settings.location

		local set_default_guide_track = timeline:GetUniqueId() == script.settings.last_timeline_id and script.settings.guide_track ~= nil and script.settings.guide_track_type ~= nil

		for _, track_data in ipairs(tracks_by_combobox_index) do
			if track_data.type ~= "separator" then
				windowItems.GuideTrackComboBox:AddItem(track_data.name)

				if set_default_guide_track and script.settings.guide_track == track_data.name and script.settings.guide_track_type == track_data.type then
					windowItems.GuideTrackComboBox.CurrentText = track_data.name
				end
			else
				windowItems.GuideTrackComboBox:InsertSeparator(windowItems.GuideTrackComboBox:Count())
			end
		end    

		windowItems.FilenameComboBox:AddItems
		{
			script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_FILENAME,
			script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_NAME,
			script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_NAME_FILTERED,
			script.constants.FILENAME_FROM.CUSTOM
		}

		windowItems.FilenameComboBox.CurrentText = script.settings.filename_from
		windowItems.CustomFilenameLineEdit.Text = script.settings.custom_filename

		windowItems.TimecodeComboBox:AddItems
		{
			script.constants.TIMECODE_FROM.GUIDE_TRACK_CLIP,
			script.constants.TIMECODE_FROM.TIMELINE,
			script.constants.TIMECODE_FROM.CUSTOM
		}

		windowItems.TimecodeComboBox.CurrentText = script.settings.timecode_from

		update_controls()
	end

	initialize_controls()

	window.On.LocationLineEdit.TextChanged = function(ev)
		update_controls()
	end

	window.On.LocationButton.Clicked = function(ev)
		local path = fusion:RequestDir(windowItems.LocationLineEdit.Text, { FReqS_Title = "Export to", })
	
		if (path) then 
			windowItems.LocationLineEdit.Text = path
			windowItems.LocationLineEdit:Home()
			windowItems.LocationLineEdit:SetSelection(0, 0)
		end
	end

	window.On.FilenameComboBox.CurrentTextChanged = function(ev)
		windowItems.CustomFilenameGroup.Hidden = windowItems.FilenameComboBox.CurrentText ~= script.constants.FILENAME_FROM.CUSTOM
		window:RecalcLayout()
	end

	window.On.TimecodeComboBox.CurrentTextChanged = function(ev)
		windowItems.CustomTimecodeGroup.Hidden = windowItems.TimecodeComboBox.CurrentText ~= script.constants.TIMECODE_FROM.CUSTOM
		windowItems.ClearRendersCheckBox.Enabled = windowItems.TimecodeComboBox.CurrentText == script.constants.TIMECODE_FROM.TIMELINE

		if windowItems.ClearRendersCheckBox.Disabled then
			windowItems.ClearRendersCheckBox.Checked = true
		else
			windowItems.ClearRendersCheckBox.Checked = script.settings.clear_completed
		end

		window:RecalcLayout()
	end

	window.On.CancelButton.Clicked = function(ev)
		dispatcher:ExitLoop()
	end
	
	window.On.RenderButton.Clicked = function(ev)
		local success, error_message = script.io:test_write_permissions(windowItems.LocationLineEdit.Text)

		if not success then
			script:show_popup( { 500, 200 }, string.format([[
				<span style="color: rgb(240, 240, 240);">
					<h3>Error</h3>
					%s<br /><br />
					<span style="color: rgb(240, 132, 132);">
						%s
					</span>
				</span>
			]], windowItems.LocationLineEdit.Text, error_message), { "OK" }, "WindowModal")

			return
		end

		-- Add a semicolon to the custom timecode if we're in a drop frame timeline
		local custom_timecode = iif(timeline:GetSetting("timelineDropFrameTimecode") == "1", string.format("%s;%s", windowItems.CustomTimecodeLineEdit.Text:sub(1, 8), windowItems.CustomTimecodeLineEdit.Text:sub(10, 11)), windowItems.CustomTimecodeLineEdit.Text)

		script.settings.render_preset = windowItems.PresetComboBox.CurrentText
		script.settings.location = windowItems.LocationLineEdit.Text
		script.settings.filename_from = windowItems.FilenameComboBox.CurrentText
		script.settings.custom_filename = windowItems.CustomFilenameLineEdit.Text
		script.settings.timecode_from = windowItems.TimecodeComboBox.CurrentText
		-- Only store the custom timecode if it's different from the timeline timecode,
		-- this way we can use the timeline timecode when initializing the control if 
		-- the setting is empty.
		script.settings.custom_timecode = iif(custom_timecode == timeline:GetStartTimecode(), nil, custom_timecode)
		script.settings.clear_completed = windowItems.ClearRendersCheckBox.Checked
		script.settings.last_timeline_id = timeline:GetUniqueId()
		script.settings.guide_track = windowItems.GuideTrackComboBox.CurrentText
		script.settings.guide_track_type = tracks_by_combobox_index[windowItems.GuideTrackComboBox.CurrentIndex + 1].type
		script.settings.stop_on_error = windowItems.StopOnErrorCheckBox.Checked
		script:save_settings()

		-- Add the custom timecode back so we can use it for rendering
		script.settings.custom_timecode = custom_timecode

		dispatcher:ExitLoop(
		{
			track_data = tracks_by_combobox_index[windowItems.GuideTrackComboBox.CurrentIndex + 1]
		})
	end

	window.On[script.window_id].KeyPress = function(ev)
		if (ev.Key == 16777216) then -- Escape
			windowItems.CancelButton:Click()
		end
	end

	window.On[script.window_id].Close = function(ev)
		windowItems.CancelButton:Click()
	end

	return window, windowItems
end

-- Used for forcing an error at specific points by giving the
-- user time to open a modal window, like Project Settings
local function wait_for_user()
	printerr("waiting")
	script.sleep(4000)
end

local function get_filenames(items, filename_mode, custom_filename, guide_track_settings)
	local function replace_variable(str, variable, variable_value)
		local v_start, v_end = str:find(variable, nil, true)

		if v_start then
			return table.concat
			{
				str:sub(1, v_start - 1),
				variable_value,
				str:sub(v_end + 1)
			}
		else
			return str
		end
	end

	local function sanitize_filename(filename)
		-- Sanitizes a filename in case it came from a clip name

		local sanitized_filename = filename:
			gsub("/", " "):
			gsub("\\", " "):
			gsub("?", " "):
			gsub("%%", " "):
			gsub("*", " "):
			gsub(":", " "):
			gsub("|", " "):
			gsub("\"", " "):
			gsub("<", " "):
			gsub(">", " ")

		-- In case we're writing to a fat32 volume that might be used elsewhere or a UNIX file system
		local reserved_words =
		{
			"null", "NULL",
			"AUX",
			"COM1", "COM2", "COM3", "COM4",
			"LPT1", "LPT1", "LPT1", "LPT1",
			"LST",
			"NUL",
			"PRN",
		}

		for _, reserved_word in ipairs(reserved_words) do
			if sanitized_filename == reserved_word then
				sanitized_filename = string.format("(%s)", reserved_word)
			end
		end

		-- Trim spaces
		return sanitized_filename:gsub("^%s+", ""):gsub("%s+$", "")
	end

	local function get_clip_name(track_type, item, media_pool_item, filename_mode)
		if track_type == "subtitle" then
			return "Subtitle"
		else
			local item_name = item:GetName()
		
			-- Trim or filter the item name file extension
			if media_pool_item and #media_pool_item:GetClipProperty("File Path") > 0 then
				local media_filename = media_pool_item:GetClipProperty("File Name")
				local media_filename_without_extension = ( { splitpath(media_filename) } )[2]

				if filename_mode == script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_FILENAME then
					item_name = media_filename_without_extension
				else
					if item_name:sub(-#media_filename) == media_filename then -- item_name ends with media_filename
						-- Trim the filename extension
						item_name = media_filename_without_extension
					elseif filename_mode == script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_NAME_FILTERED then
						-- Filter out the filename extension
						item_name = replace_variable(item_name, media_filename, media_filename_without_extension)
					end
				end
			end

			return item_name
		end
	end

	local original_filenames = {}
	local filename_data = {}

	-- Get filenames and count duplicates
	for i, item in ipairs(items) do
		local media_pool_item = item:GetMediaPoolItem()	
		local filename_by_mode = {}

		for _, mode in pairs(script.constants.FILENAME_FROM) do
			if (mode ~= script.constants.FILENAME_FROM.CUSTOM) then
				filename_by_mode[mode] = get_clip_name(guide_track_settings.track_data.type, item, media_pool_item, mode)
			end
		end

		if filename_mode == script.constants.FILENAME_FROM.CUSTOM then
			-- Replace any custom filename variables with values
			local variables =
			{
				[script.constants.VARIABLES.CLIP_FILENAME]		= filename_by_mode[script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_FILENAME],
				[script.constants.VARIABLES.CLIP_NAME]			= filename_by_mode[script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_NAME],
				[script.constants.VARIABLES.CLIP_NAME_FILTERED]	= filename_by_mode[script.constants.FILENAME_FROM.GUIDE_TRACK_CLIP_NAME_FILTERED],
				[script.constants.VARIABLES.CLIP_NUMBER]		= string.format("%s%s", string.rep("0", #tostring(#items) - #tostring(i)), i),
				[script.constants.VARIABLES.CURRENT_DATE]		= script.iso_date(),
				[script.constants.VARIABLES.CURRENT_TIME]		= script.iso_time(),
				[script.constants.VARIABLES.TRACK_NAME]			= guide_track_settings.track_data.name,
				[script.constants.VARIABLES.TRACK_NUMBER]		= tostring(guide_track_settings.track_data.index),
				[script.constants.VARIABLES.TRACK_TYPE]			= guide_track_settings.track_data.type,
			}

			local replaced_filename = custom_filename

			for variable, value in pairs(variables) do
				replaced_filename = replace_variable(replaced_filename, variable, value)
			end

			filename_by_mode[script.constants.FILENAME_FROM.CUSTOM] = replaced_filename
		end

		local filename = filename_by_mode[filename_mode]

		if original_filenames[filename] == nil then
			original_filenames[filename] = { count = 0 }
		end

		local count = original_filenames[filename].count + 1
		original_filenames[filename].count = count
		filename_data[i] =
		{
			filename = filename,
			number = count
		}
	end

	local filenames = {}

	-- We need another loop to add leading zeros to duplicate clip names as we can't know how many there are in advance
	for i = 1, #items do
		local count = original_filenames[filename_data[i].filename].count
		local number = filename_data[i].number

		local count_characters = #tostring(count)
		local filename = iif(count == 1, filename_data[i].filename, string.format("%s.%s%s", filename_data[i].filename, string.rep("0", count_characters - #tostring(number)), number))
		filenames[i] = sanitize_filename(filename)
	end

	return filenames
end

local function main()
	local project = assert(resolve:GetProjectManager():GetCurrentProject(), "Couldn't get current project")
	local timeline = assert(project:GetCurrentTimeline(), "Couldn't get current timeline")
	local window, windowItems = create_window(project, timeline)

	window:Show()
	local guide_track_settings = script.dispatcher:RunLoop()
	window:Hide()

	if guide_track_settings then
		local progress_window = script:create_progress_window("Rendering")
		progress_window:Show()

		-- Note: Some DaVinci Resolve functions have to be called via the script:retry() function
		--       because they can't run if the automated project backup is starting or if the user
		--       has opened a modal window, like Project Settings.

		if script.settings.render_preset ~= script.constants.RENDER_PRESET.CURRENT_SETTINGS then
			if not script:retry
			{
				func = project.LoadRenderPreset,
				arguments = { project, script.settings.render_preset },
				message = "Unable to load render preset: "..script.settings.render_preset,
				window = progress_window,
			}
			then
				goto exit
			end
		end

		if project:GetCurrentRenderMode() == 0 then
			-- 0 = Individual clips
			-- 1 = Single clip

			script:show_popup( { 500, 200 }, [[
				<html>
				<body>
					<h3 style="color: rgb(240, 240, 240);">Invalid Render Mode</h3>
					<p>
						DaVinci Resolve is currently set to render <span style="font-weight: bold">Individual clips</span>. Please set render to <span style="font-weight: bold">Single clip</span> (or select a suitable preset) to use this script.
					</p>
				</body>
				</html>]], { "OK" } )

			goto exit
		end

		local timeline_start_frame = timeline:GetStartFrame()
		local timeline_start_timecode = timeline:GetStartTimecode()
		local current_timeline_start_timecode = timeline_start_timecode
		local items = timeline:GetItemListInTrack(guide_track_settings.track_data.type, guide_track_settings.track_data.index)
		local filenames = get_filenames(items, windowItems.FilenameComboBox.CurrentText, windowItems.CustomFilenameLineEdit.Text, guide_track_settings)
		local file_extension = string.format(".%s", project:GetCurrentRenderFormatAndCodec().format)
		local jobs =
		{
			results = {},
			failed = 0, -- Doesn't include cancelled jobs
			completed = 0
		}

		local function get_timeline_offset(item)
			local new_file_start_frame

--			print("Timeline     timeline_start_frame: "..timeline_start_frame)
--			print("Timeline        timeline_start_tc: "..luaresolve:timecode_from_frame(timeline_start_frame, 24, false))
--			print("    Item    item:GetStart() frame: "..item:GetStart())
--			print("    Item       item:GetStart() tc: "..luaresolve:timecode_from_frame(item:GetStart(), 24, false))
			
			if script.settings.timecode_from == script.constants.TIMECODE_FROM.GUIDE_TRACK_CLIP then
				local left_offset = item:GetLeftOffset()

				if left_offset == nil then
					-- Non-Fusion Titles, Non-Fusion Generators and Subtitles don't have an offset
					--TODO: What about subclips and multicam clips? If they're generators?
					new_file_start_frame = timeline_start_frame
				else
					local media_pool_item = item:GetMediaPoolItem()

					if media_pool_item then
						-- Media pool clips, Compound clips
						--TODO: Subclips and Multicam clips
						--Note: Subclips don't have the In/Out clip properties.
						--      They also use Start/End clip properties as left/right offset compared to the full clip.
--						print("    Item                 Start TC: "..media_pool_item:GetClipProperty("Start TC"))
--						print("    Item              Start Frame: "..luaresolve:frame_from_timecode(media_pool_item:GetClipProperty("Start TC"), 24))
--						print("    Item                    Start: "..media_pool_item:GetClipProperty("Start"))
--						print("    Item                      End: "..media_pool_item:GetClipProperty("End"))
--						print("    Item               Start type: "..type(media_pool_item:GetClipProperty("Start")))
--						print("    Item                 End type: "..type(media_pool_item:GetClipProperty("End")))
--						print("    Item              left_offset: "..tostring(left_offset))
--						dump(media_pool_item:GetClipProperty())
						-- For subclips we need to add the "Start" ClipProperty that acts as the left offset
						new_file_start_frame = luaresolve:frame_from_timecode(media_pool_item:GetClipProperty("Start TC"), 24) + left_offset + media_pool_item:GetClipProperty("Start") --TODO: Frame rate of the timeline or of the clip?
					else
						-- Fusion clips, Adjustment clips
						-- We'll use the timeline start frame
						new_file_start_frame = timeline_start_frame + left_offset

						-- Note: Adjustment clips have crazy offsets, don't know if it's by design or a bug,
						-- they also seem to break the Data Burn-In feature for Source Timecode/Frame Number
					end
				end
			elseif script.settings.timecode_from == script.constants.TIMECODE_FROM.CUSTOM then
				new_file_start_frame = luaresolve:frame_from_timecode(script.settings.custom_timecode, 24) --TODO: Frame rate of the timeline or of the clip?
			else
				return timeline_start_timecode
			end
				
			local timeline_offset_frame = new_file_start_frame - (item:GetStart() - timeline_start_frame)
--			print("    Item     new_file_start_frame: "..new_file_start_frame)
--			print("Timeline    timeline_offset_frame: "..timeline_offset_frame)
--			print("Timeline timeline_offset_timecode: "..luaresolve:timecode_from_frame(timeline_offset_frame, 24, false))
--			print()
			return luaresolve:timecode_from_frame(timeline_offset_frame, 24, false) --TODO: Frame rate of the timeline or of the clip?
		end

		local function add_job_result(job_results, clip_number, items, render_settings, file_extension, status, start_timecode, end_timecode)
			local function get_remaining_message()
				if #items > clip_number then
					local remaining_jobs = #items - clip_number
					return string.format("%s remaining %s not added to the queue.", remaining_jobs, iif(remaining_jobs == 1, "job was", "jobs were"))
				else
					return ""
				end
			end

			local message = ""

			if status.JobStatus == "Failed" and status.Error then
				message = status.Error

				if windowItems.StopOnErrorCheckBox.Checked then
					message = string.format("%s<br /><br />%s", message, get_remaining_message())
				end
			elseif status.JobStatus == "Cancelled" then
				message = get_remaining_message()
			end

			job_results[#job_results+1] = string.format(
				[[
					<tr>
						<td class="spacercell" colspan="3"></td>
					</tr>
					<tr>
						<th class="headerleft" align="left" width="80">Clip %s</th>
						<th align="left">%s - %s</th>
						<th class="headerright" align="right" width="100">%s at %s%%</th>
					</tr>
					<tr>
						<td class="cell" colspan="3">%s%s</td>
					</tr>
					<tr>
						<td class="bottomcell" colspan="3">%s</td>
					</tr>
				]],
				clip_number,
				start_timecode, end_timecode,
				status.JobStatus, status.CompletionPercentage,
				render_settings.CustomName, file_extension,
				message
			)
		end

		for i, item in ipairs(items) do
			-- Save the item timline timecode in case we're adjusting it later
			local item_timeline_timecode_start = luaresolve:timecode_from_frame(item:GetStart(), 24, false) --TODO: Frame rate of the timeline or of the clip?
			local item_timeline_timecode_end = luaresolve:timecode_from_frame(item:GetEnd(), 24, false) --TODO: Frame rate of the timeline or of the clip?

			if script.settings.timecode_from == script.constants.TIMECODE_FROM.GUIDE_TRACK_CLIP or script.settings.timecode_from == script.constants.TIMECODE_FROM.CUSTOM then
				--TODO: The offset trick doesn't work when we need to have the timeline start at a negative timecode
				local new_start_timecode = get_timeline_offset(item)

				if new_start_timecode ~= current_timeline_start_timecode then
					--TODO: What happens when Live Save is on and we change the StartTimecode?
					if not script:retry
					{
						func = timeline.SetStartTimecode,
						arguments = { timeline, new_start_timecode },
						message = "Couldn't change start timecode",
						window = progress_window,
					} then
						goto errorcleanup
					else
						current_timeline_start_timecode = new_start_timecode
					end
				end
			end

			local renderSettings =
			{
				MarkIn = item:GetStart(),
				MarkOut = item:GetEnd() - 1,
				TargetDir = script.settings.location,
				CustomName = filenames[i],

				--UniqueFilenameStyle = 0, -- 0 - Prefix, 1 - Suffix
			}

			--TODO: Frame rate of the timeline or of the clip?
			script:update_progress(progress_window, "ProgressUpdated",
			{
				Progress = 100 * (i - 1) / #items,
				Status = string.format("Clip %s of %s as %s - %s",
					i,
					#items,
					luaresolve:timecode_from_frame(item:GetStart(), 24, false),
					luaresolve:timecode_from_frame(item:GetEnd(), 24, false))
			})

			if not script:retry
			{
				func = project.SetRenderSettings,
				arguments = { project, renderSettings },
				message = "Couldn't set render settings",
				window = progress_window,
			}
			then
				goto errorcleanup
			end
			
			local render_job_indexes = {}

			render_job_indexes[#render_job_indexes+1] = script:retry
			{
				func = project.AddRenderJob,
				arguments = { project },
				message = string.format("Couldn't add render job for %s", renderSettings.CustomName),
				window = progress_window,
			}

			if #render_job_indexes == 0 then
				goto errorcleanup
			end

			if not script:retry
			{
				func = project.StartRendering,
				arguments = { project, render_job_indexes, false },
				message = "Couldn't start rendering",
				window = progress_window,
			}
			then
				goto errorcleanup
			end

			while project:IsRenderingInProgress() do
				script.sleep(1000)
			end

			if current_timeline_start_timecode ~= timeline_start_timecode then
				if not script:retry
				{
					func = timeline.SetStartTimecode,
					arguments = { timeline, timeline_start_timecode },
					message = "Couldn't change start timecode",
					window = progress_window,
				}
				then
					goto errorcleanup
				else
					current_timeline_start_timecode = timeline_start_timecode
				end
			end

			local status = project:GetRenderJobStatus(render_job_indexes[1])

			if windowItems.ClearRendersCheckBox.Checked then
				script:retry
				{
					func = project.DeleteRenderJob,
					arguments = { project, render_job_indexes[1] },
					message = "Couldn't clear completed render job",
					window = progress_window,
				}

				-- Note: We're not failing if we can't clear the render job, we just leave it
			end

			if status.JobStatus == "Failed" or status.JobStatus == "Cancelled" then
				add_job_result(jobs.results, i, items, renderSettings, file_extension, status, item_timeline_timecode_start, item_timeline_timecode_end)

				if status.JobStatus == "Failed" then
					jobs.failed = jobs.failed + 1
					script:update_progress(progress_window, "SecondaryHeaderUpdated", { Status = string.format("%s failed", jobs.failed) } )

					if windowItems.StopOnErrorCheckBox.Checked then
						break
					end
				elseif status.JobStatus == "Cancelled" then
					break
				end
			elseif status.JobStatus == "Complete" then
				jobs.completed = jobs.completed + 1
			end
		end

		::errorcleanup::

		if current_timeline_start_timecode ~= timeline_start_timecode then
			print("Cleanup")

			if not script:retry
			{
				func = timeline.SetStartTimecode,
				arguments = { timeline, timeline_start_timecode },
				message = "Couldn't change start timecode",
				window = progress_window,
			}
			then
				--TODO: Popup explaining that the timeline start timecode has to be changed back manually
			else
				print("Cleanup completed")
				current_timeline_start_timecode = timeline_start_timecode
			end
		else
			print("No cleanup necessary")
		end

		::done::
		progress_window:Hide()

		if #jobs.results > 0 then
			local html = string.format([[
				<html>
				<head>
					<style>
						h3
						{
							color: rgb(240, 240, 240);
						}

						th
						{
							font-weight: normal;
							white-space: nowrap;
							border-top: 1px solid black;
							border-bottom: 1px solid black;
							background-color: rgb(47, 49, 54);
						}

						td
						{
							border-left: 1px solid black;
							border-right: 1px solid black;
							background-color: rgb(47, 49, 54);
						}

						.headerleft
						{
							color: rgb(240, 240, 240);
							border-left: 1px solid black;
						}

						.headerright
						{
							color: rgb(240, 132, 132);
							border-right: 1px solid black;
						}

						.cell
						{
							font-weight: bold;
							color: rgb(240, 240, 240);
						}

						.bottomcell
						{
							color: rgb(240, 132, 132);
							border-bottom: 1px solid black;
						}

						.spacercell
						{
							border: none;
							padding: 2px;
							background-color: transparent;
						}
					</style>
				</head>
				<body>
					<h3>%s of %s render job%s did not complete</h3>
					<table width="100%%" cellspacing="0" cellpadding="8">
						%s
					</table>
				</body>
				</html>]], #items - jobs.completed, #items, iif(#items > 1, "s", ""), table.concat(jobs.results, "\n"))

			script:show_popup( { 400, 500 }, html, { "OK" } )
		end

		::exit::
	end
end

main()

--print(script:show_popup( { 500, 200 }, "Test", { "Cancel", "OK", "Abort", "Close" } ))

--local progress_window = script:create_progress_window("Rendering")
--progress_window:Show()
--
--for i = 0, 100 do
--	script:update_progress(progress_window, "ProgressUpdated", { Progress = i, Status = "File "..tostring(i) } )
--	script:update_progress(progress_window, "SecondaryProgressUpdated", { Progress = 100 - i, Status = "File "..tostring(i), Visible = iif(i >= 50, false, true) } )
--	script.sleep(50)
--end
--
--script.dispatcher:ExitLoop()
--progress_window:Hide()
