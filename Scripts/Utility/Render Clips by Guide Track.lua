local script, luaresolve, libavutil

-- Note: Some DaVinci Resolve functions have to be called via the script:retry() function
--       because they can't run if the automated project backup is starting or if the user
--       has opened a modal window, like Project Settings.

-- Used for forcing an error at specific points by giving the
-- user time to open a modal window, like Project Settings
local function wait_for_user()
	printerr("waiting")
	script.sleep(4000)
end

--TODO: Support frame rates above 100 (three characters in the frame part of a timecode)

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
		local show_retry_progress_after = 3 -- seconds
		local retry_progress_showing = false

		while (not success) do
			local elapsed_time = os.clock() - start_time
			local time_left = timeout - elapsed_time

			if elapsed_time >= timeout then
				if self.progress_window then
					--TODO: should we have a settings.continue_after_fail bool? Now we're closing the window even if we want to continue. 
					-- Progress window
					self.dispatcher:ExitLoop()
					self.progress_window:Hide()
				end

				self:show_popup( { 500, 200 }, iif(settings.message_detail, settings.message_detail, settings.message), { "OK" } )
				
				return result
			end

			local status = string.format("%s (Retrying... %.0fs)", settings.message, time_left)

			if self.progress_window then
				script:update_progress("SecondaryProgressUpdated", { Progress = 100 * time_left / timeout, Status = status } )
				
				if not retry_progress_showing and elapsed_time >= show_retry_progress_after then
					-- Show the progress bar window in case it's hidden (checking the Hidden property doesn't work)
					self.progress_window:Show()

					-- Make the secondary progress bar visible
					script:update_progress("SecondaryProgressUpdated", { Visible = true } )
					retry_progress_showing = true
				end
			else
				print(status)
			end

			self.sleep(500)

			result = settings.func(table.unpack(settings.arguments))
			success = result ~= nil and result ~= false

			-- Hide the secondary progress bar
			if success and self.progress_window then
				script:update_progress("SecondaryProgressUpdated", { Progress = 0, Status = "", Visible = false } )
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

		local prog_win = self.dispatcher:AddWindow(
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

		local progress_items = prog_win:GetItems()

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

		prog_win.On[script.window_id.."Progress"].ProgressUpdated = function(ev)
			if ev.Status then
				progress_items.ProgressBarStatus.Text = ev.Status
			end

			if ev.Progress then
				progress_items.ProgressBar:Resize( { ev.Progress * (width - progress_margin) / 100, 1} )
			end
		end
	
		prog_win.On[script.window_id.."Progress"].SecondaryProgressUpdated = function(ev)
			if ev.Visible ~= nil then
				progress_items.SecondaryProgressBarStatus.Visible = ev.Visible
				progress_items.SecondaryProgressBarBorder.Visible = ev.Visible
				progress_items.SecondaryProgressBar.Visible = ev.Visible
			end

			if ev.Status then
				progress_items.SecondaryProgressBarStatus.Text = ev.Status
			end

			if ev.Progress then
				progress_items.SecondaryProgressBar:Resize( { ev.Progress * (width - progress_margin) / 100, 1} )
			end
		end
		
		prog_win.On[script.window_id.."Progress"].HeaderUpdated = function(ev)
			progress_items.ProgressHeader.Text = ev.Status
		end

		prog_win.On[script.window_id.."Progress"].SecondaryHeaderUpdated = function(ev)
			progress_items.SecondaryProgressHeader.Text = ev.Status
		end

		self.progress_window = prog_win._window
	end,

	update_progress = function(self, event_name, event_data)
		if self.progress_window then
			self.ui:QueueEvent(self.progress_window, event_name, event_data)
			self.dispatcher:StepLoop()
		end
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
			return tonumber(string.format("%.3f", fraction.num / fraction.den))
		end,

		scale = function(val, frame_rate1, frame_rate2)
			return val / (frame_rate1.num / frame_rate1.den) * (frame_rate2.num / frame_rate2.den)
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

	load_render_preset = function(project, render_preset)
		return script:retry
		{
			func = project.LoadRenderPreset,
			arguments = { project, render_preset },
			message = "Couldn't load render preset",
			message_detail = string.format("Couldn't load render preset \"%s\"", script.settings.render_preset)
		}
	end,

	get_timelines_folder = function(media_pool)
		local root_folder = media_pool:GetRootFolder()

		for _, folder in ipairs(root_folder:GetSubFolderList()) do
			if folder:GetName() == "Timelines" then -- Note: This should be ok for now, BMD doesn't translate this bin
				return folder			
			end
		end

		return root_folder
	end,

	get_path_by_media_pool_folder = function(media_pool, media_pool_folder)
		local root_folder = media_pool:GetRootFolder()
		local stack = table.pack(
		{
			name = "/"..root_folder:GetName(),
			folder = root_folder
		})

		while #stack > 0 do
			local current_folder_info = table.remove(stack)

			if (current_folder_info.folder == media_pool_folder) then
				return current_folder_info.name
			end

			for _, sub_folder in ipairs(current_folder_info.folder:GetSubFolderList()) do
				table.insert(stack, { name = current_folder_info.name.."/"..sub_folder:GetName(), folder = sub_folder })
			end
		end

		return nil
	end,

	traverse_media_pool = function(self, media_pool, start_folder, folder_event_handler, clip_event_handler)
		local stack = table.pack(
		{
			path = self.get_path_by_media_pool_folder(media_pool, start_folder),
			folder = start_folder
		})

		--TODO: Allow to break out of the loops from inside the event handlers

		while #stack > 0 do
			local current_folder_info = table.remove(stack)
		
			if (folder_event_handler) then
				folder_event_handler(current_folder_info.folder, current_folder_info)
			end
		
			if (clip_event_handler) then 
				for _, clip in ipairs(current_folder_info.folder:GetClipList()) do
					clip_event_handler(clip, current_folder_info)
				end
			end

			for _, sub_folder in ipairs(current_folder_info.folder:GetSubFolderList()) do
				table.insert(stack,
				{
					path = current_folder_info.path.."/"..sub_folder:GetName(),
					folder = sub_folder
				})
			end
		end
	end,

	get_timeline_media_pool_item = function(self, media_pool, timeline)
		local media_pool_item = nil

		local function timeline_equals(clip, folder_info)
			if (clip:GetClipProperty("Type") == "Timeline" --TODO: Won't work if Resolve is set to another language
				and clip:GetClipProperty("File Name") == timeline:GetName()
				and clip:GetClipProperty("Start TC") == timeline:GetStartTimecode()
				and tonumber(clip:GetClipProperty("Frames")) == timeline:GetEndFrame() - timeline:GetStartFrame()
				and clip:GetClipProperty("File Path") == "" -- This should rule out any files
				--TODO: We can still have false a match with duplicate timelines and compound clips if we can't use Type
			)
			then
				media_pool_item = clip
			end
		end

		self:traverse_media_pool(media_pool, media_pool:GetRootFolder(), nil, timeline_equals)
		return media_pool_item
	end,

	get_item_property = function(item, property_key)
		local message = "Couldn't get item property"
		local message_detail = message

		if property_key ~= nil and #property_key > 0 then
			message_detail = message_detail.."\" "..property_key.."\""
		end

		return script:retry
		{
			func = item.GetProperty,
			arguments =
			{
				item,
				property_key,
			},
			message = message,
			message_detail = message_detail,
		}
	end,

	set_timeline_setting = function(timeline, key, value)
		return script:retry
		{
			func = timeline.SetSetting,
			arguments =
			{
				timeline,
				key,
				value
			},
			message = "Couldn't set timeline setting",
			message_detail = string.format("Couldn't set timeline setting \"%s\" to \"%s\"", key, value),
		}
	end,

	create_empty_timeline = function(self, media_pool, name, template_timeline)
		local new_timeline = script:retry
		{
			func = media_pool.CreateEmptyTimeline,
			arguments =
			{
				media_pool,
				name
			},
			message = "Couldn't create timeline",
			message_detail = string.format("Couldn't create timeline \"%s\"", name),
		}

		if not new_timeline then
			return false
		else
			if template_timeline then
				local template_timeline_settings = template_timeline:GetSetting()
				
				if (template_timeline_settings.useCustomSettings == "1") then
					-- Some of the settings have to be set in a specific order for them to work,
					-- so we'll set all the known settings in order.
					local settings_order = 
					{
						"useCustomSettings",

						-- Format
						"timelineResolutionWidth",
						"timelineResolutionHeight",
						"timelinePixelAspectRatio",
						"timelineFrameRate",
						"timelineDropFrameTimecode",
						"timelineInterlaceProcessing",
						"timelineInputResMismatchBehavior",

						-- Monitor
						"videoMonitorFormat",
						"videoMonitorUse444SDI",
						"videoMonitorUseLevelA",
						"videoMonitorUseStereoSDI",
						"videoMonitorSDIConfiguration",
						"videoDataLevels",
						"videoDataLevelsRetainSubblockAndSuperWhiteData",
						"videoMonitorBitDepth",
						"videoMonitorScaling",
						"videoMonitorUseMatrixOverrideFor422SDI",
						"videoMonitorMatrixOverrideFor422SDI",
						"videoMonitorUseHDROverHDMI",

						-- Output
						"timelineOutputResMatchTimelineRes",
						"timelineOutputResolutionWidth",
						"timelineOutputResolutionHeight",
						"timelineOutputPixelAspectRatio",
						"timelineOutputResMismatchBehavior",
						"superScale",
					}

					for _, key in ipairs(settings_order) do
						if not self.set_timeline_setting(new_timeline, key, template_timeline_settings[key]) then
							return false
						end

						template_timeline_settings[key] = nil
					end

					-- Any remaining settings
					for key, value in pairs(template_timeline_settings) do
						if not self.set_timeline_setting(timeline, key, value) then
							return false
						end
					end
				end
			end

			return new_timeline
		end
	end,

	append_to_timeline = function(media_pool, clip_info)
		return script:retry
		{
			func = media_pool.AppendToTimeline,
			arguments =
			{
				media_pool,
				clip_info
			},
			message = "Couldn't append clips to the current timeline",
		}
	end,

	set_render_settings = function(project, settings)
		return script:retry
		{
			func = project.SetRenderSettings,
			arguments =
			{
				project,
				settings
			},
			message = "Couldn't set render settings",
		}
	end,

	add_render_job = function(project, filename)
		return script:retry
		{
			func = project.AddRenderJob,
			arguments = { project },
			message = "Couldn't add render job",
			message_detail = iif(filename, string.format("Couldn't add render job for \"%s\"", filename), nil),
		}
	end,

	set_start_timecode = function(timeline, timecode)
		return script:retry
		{
			func = timeline.SetStartTimecode,
			arguments = { timeline, timecode },
			message = "Couldn't set start timecode",
			message_detail = string.format("Couldn't set start timecode to %s", timecode),
		}
	end,

	start_rendering = function(project, render_job_ids, is_interactive_mode)
		return script:retry
		{
			func = project.StartRendering,
			arguments = { project, render_job_ids, is_interactive_mode },
			message = "Couldn't start rendering",
		}
	end,

	delete_render_job = function(project, render_job_id)
		return script:retry
		{
			func = project.DeleteRenderJob,
			arguments = { project, render_job_id },
			message = "Couldn't delete render job",
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
					InputMask = "99:99:99:99", -- Note: DropFrame timecode with a semicolon doesn't work here because of a bug in Qt (https://bugreports.qt.io/browse/QTBUG-1588)
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

local function main()
	local function populate_timeline_properties(t, media_pool, guide_track_settings)
		assert(t and t.Current, "\"t.Current\" has to have a value before running populate_timeline_properties()")

		t.FrameRate = luaresolve.frame_rates:get_decimal(t.Current:GetSetting("timelineFrameRate"))
		t.FractionalFrameRate = luaresolve.frame_rates:get_fraction(t.FrameRate)
		t.DropFrame = t.Current:GetSetting("timelineDropFrameTimecode") == "1"

		t.Start = 
		{
			Frame = t.Current:GetStartFrame(),
			Timecode = t.Current:GetStartTimecode()
		}

		t.End =
		{
			Frame = t.Current:GetEndFrame(),
			Timecode = luaresolve:timecode_from_frame(t.Current:GetEndFrame(), t.FrameRate, t.DropFrame),
		}

		t.MediaPoolItem = luaresolve:get_timeline_media_pool_item(media_pool, t.Current)

		t.In = { Timecode = t.MediaPoolItem:GetClipProperty("In") }
		t.Out =  { Timecode = t.MediaPoolItem:GetClipProperty("Out") }
		
		if #t.In.Timecode == 0 then
			t.In.Frame = t.Start.Frame
			t.In.Timecode = t.Start.Timecode
		else
			t.In.Frame = luaresolve:frame_from_timecode(t.In.Timecode, t.FrameRate)
		end

		if #t.Out.Timecode == 0 then
			t.Out.Frame = t.End.Frame
			t.Out.Timecode = luaresolve:timecode_from_frame(t.Out.Frame, t.FrameRate, t.DropFrame)
		else
			t.Out.Frame = luaresolve:frame_from_timecode(t.Out.Timecode, t.FrameRate)
		end
	end

	local function get_clips(t, filename_mode, custom_filename, guide_track_settings)
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
		local clip_properties = {}
		t.Items = {}

		-- Filter out transitions
		for i, item in ipairs(t.Current:GetItemListInTrack(guide_track_settings.track_data.type, guide_track_settings.track_data.index)) do
			local item_properties = luaresolve.get_item_property(item)

			if item_properties == nil then
				return nil
			end

			-- Hack: Hopefully nothing else will get filtered out
			if next(item_properties) then
				t.Items[#t.Items+1] = item
			end
		end

		-- Get filenames and count duplicates
		for i, item in ipairs(t.Items) do
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
					[script.constants.VARIABLES.CLIP_NUMBER]		= string.format("%s%s", string.rep("0", #tostring(#t.Items) - #tostring(i)), i),
					[script.constants.VARIABLES.CURRENT_DATE]		= script.iso_date(),
					[script.constants.VARIABLES.CURRENT_TIME]		= script.iso_time():gsub(":", "."),
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

			clip_properties[#clip_properties+1] =
			{
				filename = filename,
				number = count,
				item = item,
				media_pool_item = media_pool_item,
			}
		end

		local clips = {}

		-- We need another loop to add leading zeros to duplicate clip names as we can't know how many there are in advance
		for i = 1, #t.Items do
			local count = original_filenames[clip_properties[i].filename].count
			local number = clip_properties[i].number

			local count_characters = #tostring(count)
			local filename = iif(count == 1, clip_properties[i].filename, string.format("%s.%s%s", clip_properties[i].filename, string.rep("0", count_characters - #tostring(number)), number))

			clips[i] =
			{
				Filename = sanitize_filename(filename),
				Item = clip_properties[i].item,
				MediaPoolItem = clip_properties[i].media_pool_item,
			}
		end

		return clips
	end

	local function get_timeline_start_end(clip, t, timeline_offset)
		local new_file_start_frame

		if script.settings.timecode_from == script.constants.TIMECODE_FROM.GUIDE_TRACK_CLIP then
			local left_offset = clip.Item:GetLeftOffset()

			if left_offset == nil then
				-- Non-Fusion Titles, Non-Fusion Generators, Subtitles and Transitions don't have an offset
				--TODO: What about subclips and multicam clips? If they're generators?
				new_file_start_frame = t.Start.Frame
			else
				if clip.MediaPoolItem then
					-- Media pool clips, Compound clips
					--TODO: Subclips and Multicam clips
					--Note: Subclips don't have the In/Out clip properties.
					--      They also use Start/End clip properties as left/right offset compared to the full clip.

					local start_tc = clip.MediaPoolItem:GetClipProperty("Start TC")
					local start = clip.MediaPoolItem:GetClipProperty("Start")

					if t.FrameRate ~= clip.FrameRate then
						-- Scale "Start TC" and "Start" ClipProperties to the timeline frame rate
						start_tc = string.format("%s%02d", start_tc:sub(1, 9), math.floor(luaresolve.frame_rates.scale(tonumber(start_tc:sub(-2)), clip.FractionalFrameRate, t.FractionalFrameRate)))
						start = math.floor(luaresolve.frame_rates.scale(start, clip.FractionalFrameRate, t.FractionalFrameRate))
						--TODO: Verify upscale/downscale
					end

					-- For subclips we need to add the "Start" ClipProperty that acts as the left offset
					new_file_start_frame = luaresolve:frame_from_timecode(start_tc, t.FrameRate) + left_offset + start
				else
					-- Fusion clips, Adjustment clips
					-- We'll use the timeline start frame
					new_file_start_frame = t.Start.Frame + left_offset

					-- Note: Adjustment clips have crazy offsets, don't know if it's by design or a bug,
					-- they also seem to break the Data Burn-In feature for Source Timecode/Frame Number
				end
			end

			new_file_start_frame = new_file_start_frame + timeline_offset
		elseif script.settings.timecode_from == script.constants.TIMECODE_FROM.CUSTOM then
			new_file_start_frame = luaresolve:frame_from_timecode(script.settings.custom_timecode, t.FrameRate) + timeline_offset
		else
			new_file_start_frame = clip.Start.Frame
		end

		return new_file_start_frame, new_file_start_frame + clip.End.Frame - clip.Start.Frame 
	end

	local function populate_item_properties(t, clips)
		for i, clip in ipairs(clips) do
			local item = clip.Item
			local item_start = item:GetStart()
			local item_end = item:GetEnd()
			local timeline_offset = 0

			local in_out_contains_whole_clip = item_start >= t.In.Frame and item_end <= t.Out.Frame + 1
			local in_out_cuts_clip_start_and_end = item_start < t.In.Frame and item_end > t.Out.Frame + 1
			local in_out_cuts_clip_start = item_start < t.In.Frame and item_end > t.In.Frame and item_end <= t.Out.Frame + 1
			local in_out_cuts_clip_end = item_start >= t.In.Frame and item_start < t.Out.Frame + 1 and item_end > t.Out.Frame + 1
			local render_clip = in_out_contains_whole_clip or in_out_cuts_clip_start_and_end or in_out_cuts_clip_start or in_out_cuts_clip_end

			if in_out_cuts_clip_start_and_end then
				timeline_offset = t.In.Frame - item_start
				item_start = t.In.Frame
				item_end = t.Out.Frame + 1
			elseif in_out_cuts_clip_start then
				timeline_offset = t.In.Frame - item_start
				item_start = t.In.Frame
			elseif in_out_cuts_clip_end then
				item_end = t.Out.Frame + 1
			end

			local clip_frame_rate = t.FrameRate
			local clip_fractional_frame_rate = luaresolve.frame_rates:get_fraction(clip_frame_rate)
			local clip_drop_frame = t.DropFrame

			if clip.MediaPoolItem then
				clip_frame_rate = luaresolve.frame_rates:get_decimal(clip.MediaPoolItem:GetClipProperty("FPS"))
				clip_fractional_frame_rate = luaresolve.frame_rates:get_fraction(clip_frame_rate)
				clip_drop_frame = clip.MediaPoolItem:GetClipProperty("Drop frame") == "1" --TODO: Are these translated?
			end

			clip.FrameRate = clip_frame_rate
			clip.FractionalFrameRate = clip_fractional_frame_rate
			clip.DropFrame = clip_drop_frame

			clip.Start =
			{
				Frame = item_start,
				Timecode = luaresolve:timecode_from_frame(item_start, t.FrameRate, t.DropFrame)
			}

			clip.End = 
			{
				Frame = item_end,
				Timecode = luaresolve:timecode_from_frame(item_end, t.FrameRate, t.DropFrame)
			}
			
			local new_timeline_start_frame, new_timeline_end_frame = get_timeline_start_end(clip, t, timeline_offset)

			clip.TimelineStart =
			{
				Frame = new_timeline_start_frame,
				Timecode = luaresolve:timecode_from_frame(new_timeline_start_frame, t.FrameRate, t.DropFrame)
			}

			clip.TimelineEnd =
			{
				Frame = new_timeline_end_frame,
				Timecode = luaresolve:timecode_from_frame(new_timeline_end_frame, t.FrameRate, t.DropFrame)
			}

			if render_clip then
				if clips.ClipsToRender == nil then
					clips.ClipsToRender = {}
				end

				clips.ClipsToRender[#clips.ClipsToRender+1] = 
				{
					Clip = clip,
				}
			end
		end
	end

	local function create_timelines(media_pool, t, clips)
		for i, clip_to_render in ipairs(clips.ClipsToRender) do
			local clip = clip_to_render.Clip

			script:update_progress("ProgressUpdated",
			{
				Progress = 100 * i / #clips.ClipsToRender,
				Status = string.format("Timeline %s of %s as %s - %s", i, #clips.ClipsToRender, clip.TimelineStart.Timecode, clip.TimelineEnd.Timecode)
			})
			
			clip_to_render.Timeline = luaresolve:create_empty_timeline(media_pool, string.format("[%s] %s", i, bmd.createuuid()), t.Current)

			if clip_to_render.Timeline == nil then
				return nil
			else
				if not luaresolve.append_to_timeline(media_pool, {
				{
					mediaPoolItem = t.MediaPoolItem,
					startFrame = clip.Start.Frame - t.Start.Frame,
					endFrame = clip.End.Frame - t.Start.Frame - 1
				}})
				then
					return nil
				end

				if not luaresolve.set_start_timecode(clip_to_render.Timeline, clip.TimelineStart.Timecode) then
					return nil
				end
			end
		end

		return true
	end

	local function queue_render_job(project, timeline, settings)
		if timeline then
			project:SetCurrentTimeline(timeline)
		end

		if not luaresolve.set_render_settings(project, settings) then
			return nil
		end
			
		return luaresolve.add_render_job(project, settings.CustomName)
	end

	local function add_job_result(job_results, clip_number, filename, file_extension, status, start_timecode, end_timecode)
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
			filename, file_extension,
			iif(status.JobStatus == "Failed" and status.Error, status.Error, "")
		)
	end

	local project = assert(resolve:GetProjectManager():GetCurrentProject(), "Couldn't get current project")
	local t = { Current = assert(project:GetCurrentTimeline(), "Couldn't get current timeline") } --TODO: Remove asserts
	local window = create_window(project, t.Current)

	window:Show()
	local guide_track_settings = script.dispatcher:RunLoop()
	window:Hide()

	if guide_track_settings then
		script:create_progress_window("Creating timelines")

		if script.settings.render_preset ~= script.constants.RENDER_PRESET.CURRENT_SETTINGS then
			if not luaresolve.load_render_preset(project, script.settings.render_preset) then
				return
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
		
			return
		end

		do
			local media_pool = project:GetMediaPool()
			local current_folder = media_pool:GetCurrentFolder()
			local timelines_folder = luaresolve.get_timelines_folder(media_pool)
			populate_timeline_properties(t, media_pool, guide_track_settings)
			local clips = get_clips(t, script.settings.filename_from, script.settings.custom_filename, guide_track_settings)

			if clips == nil then
				return
			end

			populate_item_properties(t, clips)
			clips.Jobs = {}
			clips.Results = {}
			
			local file_extension = string.format(".%s", project:GetCurrentRenderFormatAndCodec().format)
			local folder

			if script.settings.timecode_from ~= script.constants.TIMECODE_FROM.TIMELINE then
				resolve:OpenPage("media")

				-- Create a temporary bin
				folder = media_pool:AddSubFolder(timelines_folder, bmd.createuuid())
				media_pool:SetCurrentFolder(folder)

				script.progress_window:Show()

				-- We'll create all the timelines first before queuing render jobs so Resolve doesn't keep switching between pages
				if not create_timelines(media_pool, t, clips) then
					goto errorcleanup
				end
			else
				script.progress_window:Show()
			end

			script:update_progress("HeaderUpdated", { Status = "Adding render jobs" } )

			-- Now set up the render jobs
			for i, clip_to_render in ipairs(clips.ClipsToRender) do
				script:update_progress("ProgressUpdated",
				{
					Progress = 100 * i / #clips.ClipsToRender,
					Status = string.format("Job %s of %s", i, #clips.ClipsToRender)
				})
			
				clips.Jobs[i] = queue_render_job(project, clip_to_render.Timeline, 
				{
					TargetDir = script.settings.location,
					CustomName = clip_to_render.Clip.Filename,
					MarkIn = iif(script.settings.timecode_from == script.constants.TIMECODE_FROM.TIMELINE, clip_to_render.Clip.Start.Frame, nil),
					MarkOut = iif(script.settings.timecode_from == script.constants.TIMECODE_FROM.TIMELINE, clip_to_render.Clip.End.Frame - 1, nil),
				})

				if clips.Jobs[i] == nil then
					goto errorcleanup
				end
			end

			script.progress_window:Hide()

			-- Render
			if not luaresolve.start_rendering(project, clips.Jobs, false) then
				goto errorcleanup
			end
		
			-- Wait for renders to complete
			while project:IsRenderingInProgress() do
				script.sleep(1000)
			end

			-- Delete render jobs
			for i = 1, #clips.Jobs do
				local clip = clips.ClipsToRender[i].Clip
				local status = project:GetRenderJobStatus(clips.Jobs[i])
			
				luaresolve.delete_render_job(project, clips.Jobs[i])
				-- Note: We're not failing if we can't delete the render jobs, we just leave it
			
				if status.JobStatus == "Failed" or status.JobStatus == "Cancelled" then
					add_job_result(clips.Results, i, clip.Filename, file_extension, status, clip.Start.Timecode, clip.End.Timecode)
				end
			end

			if script.settings.timecode_from ~= script.constants.TIMECODE_FROM.TIMELINE then
				-- Delete the temporary bin (and the timelines in it)
				media_pool:DeleteFolders( { folder } )

				media_pool:SetCurrentFolder(current_folder)
				project:SetCurrentTimeline(t.Current)
			else
				-- Here we would like to restore any In/Out points on the timeline since the
				-- render settings will have changed them, but it's currently not possible.
			end

			::errorcleanup::
			print("errorcleanup")

			script.dispatcher:ExitLoop()
			script.progress_window:Hide()

			if #clips.Results > 0 then
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
					</html>]], #clips.Results, #clips.Jobs, iif(#clips.Jobs > 1, "s", ""), table.concat(clips.Results, "\n"))

				script:show_popup( { 400, 500 }, html, { "OK" } )
			end
		end
	end
end

main()

--print(script:show_popup( { 500, 200 }, "Test", { "Cancel", "OK", "Abort", "Close" } ))

--script.progress_window = script:create_progress_window("Rendering")
--script.progress_window:Show()
--
--for i = 0, 100 do
--	script:update_progress("ProgressUpdated", { Progress = i, Status = "File "..tostring(i) } )
--	script:update_progress("SecondaryProgressUpdated", { Progress = 100 - i, Status = "File "..tostring(i), Visible = iif(i >= 50, false, true) } )
--	script.sleep(50)
--end
--
--script.dispatcher:ExitLoop()
--script.progress_window:Hide()
