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


	Blah, blah. Since there's no Folder.GetParent() function in the API, traversing the hierarchy of bins 
	isn't very efficient. Luckily it's pretty fast so it's not a big deal.


	Known issues: It's just cosmetic, but Folder.GetSubFolderList() doesn't adhere to the sort order set by the user. 

	roger.magnusson@gmail.com


]]

local script, luaresolve, libavutil, log

script = 
{
	filename = debug.getinfo(1,"S").source:match("^.*%@(.*)"),
	version = "1.0",
	name = "Set Timecode for Media Pool Clips",
	window_id = "SetTimecodeForMediaPoolClips",
	default_timeout = 30, -- seconds
	default_timeout_action = "stop", -- "continue", "inquire", "stop"

	settings =
	{
		include_sub_bins = true,
		mode = nil,
		timecode = "00:00:00:00",
		offset_frames = 0,
		copy_original_tc = true,
		skip_clips_in_use = true,
		show_log = true,
	},

	constants =
	{
		MODE =
		{
			SET_TIMECODE = "Set timecode",
			ADD_TIMECODE = "Add timecode",
			SUBTRACT_TIMECODE = "Subtract timecode",
			OFFSET_FRAMES = "Offset frames",
			RESTORE_FROM_AUDIO_START_TC = "Restore original timecode from Audio Start TC metadata",
		},

		METADATA_VALUES =
		{
			ORIGINAL_TC = "Original TC",
		}
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
		local function set_sleep_declarations()
			if ffi.os == "Windows" then
				ffi.cdef[[
					void Sleep(int ms);
				]]
			else
				ffi.cdef[[
					int poll(struct pollfd *fds, unsigned long nfds, int timeout);
				]]
			end
		end

		set_sleep_declarations()
		libavutil.set_declarations()
	end,

	retry = function(self, settings)
		--settings = 
		--{
		--	func = function,
		--	arguments = {},
		--	message = "Error message shown in progress bar",
		--
		--	[Optional]
		--	message_detail = "Detailed error message, shown in popup and returned from retry() on error. If not provided, [message] is used instead.",
		--	timeout = 60, -- Default is defined by script.default_timeout
		--	timeout_action = "stop", -- Default is defined by script.default_timeout_action
		--}

		-- Execute the provided function
		local result = settings.func(table.unpack(settings.arguments))
		local success = result ~= nil and result ~= false

		local start_time = bmd.gettime()
		local timeout = iif(settings.timeout, settings.timeout, self.default_timeout)
		local timeout_action = iif(settings.timeout_action, settings.timeout_action, self.default_timeout_action)
		local show_retry_progress_after = 3 -- seconds
		local retry_progress_showing = false
		local error_message = iif(settings.message_detail, settings.message_detail, settings.message)
		local close_progress_on_error = true
		local popup_controls = script.ui:TextEdit
		{
			Weight = 1,
			Text = error_message,
			ReadOnly = true,
			TextFormat = { RichText = true },
			TextInteractionFlags = 
			{
				TextSelectableByKeyboard = false,
				LinksAccessibleByMouse = false,
				LinksAccessibleByKeyboard = false,
				TextEditable = false,
				NoTextInteraction = false,
				TextSelectableByMouse = true,
			},
			StyleSheet = [[
				QTextEdit
				{
					border: none;
					color: rgb(240, 133, 133);
				}
			]],
		}

		while (not success) do
			local elapsed_time = bmd.gettime() - start_time
			local time_left = timeout - elapsed_time

			if elapsed_time >= timeout then
				-- Timeout has expired, determine what to do

				if timeout_action == "continue"
					or (timeout_action == "inquire" and self:show_popup( { WindowTitle = string.format("%s - Error", script.name), FixedSize = { 500, 200 } }, popup_controls, { "Continue", "Stop" } ) == "continue")
				then
					close_progress_on_error = false

					-- Hide the secondary progress bar
					if self.progress_window then
						script:update_progress("SecondaryProgressUpdated", { Progress = 0, Status = "", Visible = false } )
					end
				end

				if close_progress_on_error and self.progress_window then
					-- Progress window
					self.dispatcher:ExitLoop()
					self.progress_window:Hide()
				end
				
				return result, error_message, iif(close_progress_on_error, "stop", "continue")
			end

			local status = string.format("%s (Retrying... %.0fs)", settings.message, time_left)

			-- Update progress
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

			-- Retry
			result = settings.func(table.unpack(settings.arguments))
			success = result ~= nil and result ~= false

			-- Hide the secondary progress bar
			if success and self.progress_window then
				script:update_progress("SecondaryProgressUpdated", { Progress = 0, Status = "", Visible = false } )
			end
		end

		return result
	end,

	sleep = function(milliseconds)
		if ffi.os == "Windows" then
			ffi.C.Sleep(milliseconds)
		else
			ffi.C.poll(nil, 0, milliseconds)
		end
	end,

	show_popup = function(self, window_properties, controls, buttons)
		local popup_window_id = self.window_id.."PopUp"
		
		local default_window_properties =
		{
			ID = popup_window_id,
			WindowTitle = self.name,
			WindowFlags =
			{
				Dialog = true,
				WindowTitleHint = true,
				WindowCloseButtonHint = true,
			},

			WindowModality = "None",

			Events = 
			{
				Close = true,
				KeyPress = true,
			},

			FixedSize =
			{
				570,
				260,
			},
		}

		self.merge_table(default_window_properties, window_properties)

		default_window_properties[#default_window_properties+1] = self.ui:VGroup
		{
			MinimumSize = { 200, 150 },
			MaximumSize = { 16777215, 16777215 },

			controls,

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
		}

		local popup_window = self.dispatcher:AddWindow(default_window_properties)
		local popup_items = popup_window:GetItems()

		-- Add buttons and events
		for index, button in ipairs(buttons) do
			popup_items.ButtonsGroup:AddChild(self.ui:Button
			{
				ID = popup_window_id..button,
				Text = button,
				AutoDefault = false,
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
	
	merge_table = function(a, b)
		if a and b then
			for key, value in pairs(b) do
				a[key] = value
			end
		end
	end,

	log_settings =
	{
		columns = 
		{
			index = 
			{
				display_name = "#",
				width = 40,
			},

			bin =
			{
				display_name = "Bin",
				width = 250,
			},

			clip_name =
			{
				display_name = "Clip Name",
				width = 200,
			},

			type =
			{
				display_name = "Type",
				width = 100,
			},

			start_tc =
			{
				display_name = "Old Start TC",
				width = 85,
			},

			new_start_tc =
			{
				display_name = "New Start TC",
				width = 85,
			},

			status =
			{
				display_name = "Status",
				width = 80,
				use_status_colors = true,
			},
		},

		columns_order = { "index", "bin", "clip_name", "type", "start_tc", "new_start_tc", "status" },

		get_header = function(self)
			if log.total_item_count == 0 then
				return "No media pool clips to process"
			else
				if script.settings.mode == script.constants.MODE.RESTORE_FROM_AUDIO_START_TC then
					if log.updated_items > 0 then
						return string.format("Timecode was restored on %s of %s media pool clips", log.updated_items, log.total_item_count)
					else
						return "Timecode was not restored on any media pool clips"
					end
				else
					if log.updated_items > 0 then
						if script.settings.mode == script.constants.MODE.OFFSET_FRAMES then
							return string.format("Timecode was set to %s frame%s on %s of %s media pool clips", iif(script.settings.offset_frames < 0, tostring(script.settings.offset_frames), "+"..tostring(script.settings.offset_frames)), iif(script.settings.offset_frames == 1, "", "s"), log.updated_items, log.total_item_count)
						else
							return string.format("Timecode was set to %s on %s of %s media pool clips", script.settings.timecode, log.updated_items, log.total_item_count)
						end
					else
						return "Timecode was not set on any media pool clips"
					end
				end
			end
		end,

		get_footer = function(self)
			if #log.tree_items < log.total_item_count then
				return string.format("%s remaining media pool clips were not processed", log.total_item_count - #log.tree_items)
			end
		end,
	},

	media_pool = {},

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

	get_media_pool_tree = function(self, media_pool)
		local root_folder = media_pool:GetRootFolder()
		local current_folder = media_pool:GetCurrentFolder()
		local start_folder = root_folder
		local recursive = true

		-- GetCurrentFolder() returns nil if more than one folder is selected
		if current_folder == nil then
			current_folder = root_folder
		end

		local function get_folder_tree(start_folder, recursive)
			local metatables =
			{
				folder = 
				{
					__index =
					{
						-- Provide a function to traverse the folder by branch.
						-- function_settings:
						-- {
						--     folder_function = function(folder_info),
						--     media_pool_item_function = function(media_pool_item_info),
						--     media_pool_item_sort_function = function(media_pool_item_info_a, media_pool_item_info_b),
						-- }
						traverse_by_branch = function(self, function_settings)
							local function next_folder(folder_info)
								if folder_info.parent ~= nil and #folder_info.parent.sub_folders >= folder_info.index + 1 then
									return folder_info.parent.sub_folders[folder_info.index + 1]
								else
									return nil
								end
							end

							if function_settings then
								local folder_info = self
								local break_while = false

								while folder_info ~= nil and (folder_info.level > self.level or folder_info == self) do
									if function_settings.folder_function then
										if function_settings.folder_function(folder_info) == false then
											break_while = true	
										end
									end

									if function_settings.media_pool_item_function then
										if function_settings.media_pool_item_sort_function then
											table.sort(folder_info.media_pool_items, function_settings.media_pool_item_sort_function)
										end

										for _, media_pool_item_info in ipairs(folder_info.media_pool_items) do
											if function_settings.media_pool_item_function(media_pool_item_info) == false then
												break_while = true
												break -- Break the for loop
											end
										end
									end

									if break_while then
										break -- Break the while loop
									end

									if #folder_info.sub_folders > 0 then
										-- Go to the first sub folder
										folder_info = folder_info.sub_folders[1]
									else
										while folder_info ~= nil and next_folder(folder_info) == nil and folder_info.unique_id ~= self.unique_id do
											-- No more folders, go up to parent
											folder_info = folder_info.parent
										end

										if folder_info ~= nil then
											-- Go to next folder
											folder_info = next_folder(folder_info)
										end
									end
								end
							end
						end,

						-- Provide a function to count the media pool items in this folder and any sub folders
						get_recursive_item_count = function(self)
							local count = 0

							self:traverse_by_branch
							{
								folder_function = function(count_folder_info)
									count = count + #count_folder_info.media_pool_items
								end
							}

							return count
						end,
					},

					__tostring = function(self)
						return self.path
					end,
				},

				media_pool_item =
				{
					__tostring = function(self)
						return self.clip_name
					end
				},
			}

			local function get_media_pool_item_info(media_pool_item, index, folder_info)
				-- Note: Getting clip properties affects performance, but we need the "Clip Name" property to be able
				-- to sort clips as GetClipList() is not guaranteed to return clips in the expected order.
				local clip_properties = media_pool_item:GetClipProperty()

				local media_pool_item_info =
				{
					index = index,
					media_pool_item = media_pool_item,
					folder = folder_info,

					clip_name = clip_properties["Clip Name"],
					start_tc = clip_properties["Start TC"],
					type = clip_properties["Type"],
					format = clip_properties["Format"],
					usage = clip_properties["Usage"],
					fps = clip_properties["FPS"],
					drop_frame = clip_properties["Drop frame"],

					-- Note: Adding these starts to affect performance even more
					--unique_id = media_pool_item:GetUniqueId(),
					--media_id = media_pool_item:GetMediaId(),
					--name = media_pool_item:GetName(),
				}

				setmetatable(media_pool_item_info, metatables.media_pool_item)

				return media_pool_item_info
			end

			local function get_folder_info(folder, level, index, parent_folder_info)
				local unique_id = folder:GetUniqueId()
				local name = folder:GetName()

				local folder_info =
				{
					level = level,
					index = index,
					unique_id = unique_id,
					name = name,
					is_current = folder == current_folder,
					is_root = folder == root_folder,
					folder = folder,
					parent = parent_folder_info,
				}

				if parent_folder_info == nil then
					folder_info.sub_folders = {}
				else
					parent_folder_info.sub_folders[#parent_folder_info.sub_folders+1] = folder_info
				end

				folder_info.media_pool_items = {}
				
				for media_pool_item_index, media_pool_item in ipairs(folder_info.folder:GetClipList()) do
					folder_info.media_pool_items[#folder_info.media_pool_items+1] = get_media_pool_item_info(media_pool_item, media_pool_item_index, folder_info)
				end

				setmetatable(folder_info, metatables.folder)

				return folder_info
			end

			local start_folder_info = get_folder_info(start_folder, 1, 1, nil)
			start_folder_info.total_item_count = 0
			start_folder_info.folder_info_by_unique_id = {}

			if recursive then
				local stack = { start_folder_info }

				while #stack > 0 do
					local folder_info = table.remove(stack)
					start_folder_info.total_item_count = start_folder_info.total_item_count + #folder_info.media_pool_items
					
					folder_info.sub_folders = {}

					for index, sub_folder in ipairs(folder_info.folder:GetSubFolderList()) do
						table.insert(stack, 1, get_folder_info(sub_folder, folder_info.level + 1, index, folder_info))
					end

					start_folder_info.folder_info_by_unique_id[folder_info.unique_id] = folder_info
				end
			else
				start_folder_info.folder_info_by_unique_id[start_folder_info.unique_id] = start_folder_info
			end

			return start_folder_info
		end

		local function set_path(folder_info)
			local path = ""
			local unique_id_path = ""
			local current_folder_info = folder_info
				
			while current_folder_info ~= nil do
				if current_folder_info.path == nil then
					-- Path needs to be constructed by going up to the parent
					path = string.format("%s%s%s", iif(current_folder_info.parent, "/", ""), current_folder_info.name, path)
					unique_id_path = string.format("%s%s%s", iif(current_folder_info.parent, "/", ""), current_folder_info.unique_id, unique_id_path)
					current_folder_info = current_folder_info.parent
				else
					-- We're on a parent folder where the path is already set, use that path and break out of the loop
					path = string.format("%s%s", current_folder_info.path, path)
					unique_id_path = string.format("%s%s", current_folder_info.unique_id, unique_id_path)
					break							
				end
			end

			folder_info.path = path
			folder_info.unique_id_path = unique_id_path
		end

		-- Get all folders
		local tree = get_folder_tree(start_folder, recursive)

		-- We'll use this as a lookup table
		tree.folder_info_by_branch = {}

		-- Traverse through all folders, ordered by branch
		tree:traverse_by_branch
		{
			folder_function = function(folder_info)
				-- Add folder to the lookup table
				tree.folder_info_by_branch[#tree.folder_info_by_branch+1] = folder_info

				-- Set the complete path for the folder
				set_path(folder_info)

				if folder_info.is_current then
					-- Store a reference to the currently selected folder in the tree root
					tree.current = folder_info
				end
			end
		}

		return tree
	end,

	set_clip_property = function(media_pool_item, property_key, property_value)
		local message = "Couldn't set clip property"
		local message_detail = message

		if property_key ~= nil and #property_key > 0 then
			message_detail = message_detail.." \""..property_key.."\""
		end

		if property_value ~= nil then
			message_detail = message_detail.." to \""..property_value.."\""
		end

		return script:retry
		{
			func = media_pool_item.SetClipProperty,
			arguments =
			{
				media_pool_item,
				property_key,
				property_value,
			},
			message = message,
			message_detail = message_detail,
		}
	end,
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

log =
{
	total_item_count = 0,
	updated_items = 0,
	error = false,
	last_error_item = nil,

	initialize = function(self, log_settings)
		self.settings = log_settings
		
		self.tree = script.ui:Tree
		{
			Weight = 1,
			ID = "_LogTree",
			AlternatingRowColors = true,
			RootIsDecorated = false,
			SelectionMode = "NoSelection",
		}

		self.tree_items = {}
	end,

	write = function(self, log_entry)
		local log_item = self.tree:NewItem()
		local status_column_index = 0

		for i, column_name in ipairs(self.settings.columns_order) do
			log_item:SetData(i - 1, "DisplayRole", log_entry[column_name])

			if self.settings.columns[column_name].use_status_colors then
				-- Status codes: "ok", "skipped", "warning", "error"
				if log_entry.status_code == "warning" then
					log_item.TextColor[i - 1] = { R = 0.941, G = 0.753, B = 0.333, A = 1 }
				elseif log_entry.status_code == "error" then
					log_item.TextColor[i - 1] = { R = 0.941, G = 0.518, B = 0.518, A = 1 }
				end
			end
		end
			
		self.tree_items[#self.tree_items+1] = log_item

		if log_entry.status_code == "error" then
			self.last_error_item = log_item
		end
	end,

	show = function(self)
		local ui = script.ui
		self.tree.ColumnCount = #self.settings.columns_order
		local header_labels = {}
		local html_stylesheet = [[
			.error { color: rgb(240, 133, 133); }
		]]
		local column

		for i, column_name in ipairs(self.settings.columns_order) do
			column = self.settings.columns[column_name]
			header_labels[#header_labels+1] = column.display_name
			self.tree.ColumnWidth[i - 1] = column.width
		end

		self.tree:SetHeaderLabels(header_labels)
		self.tree:AddTopLevelItems(self.tree_items)

		local function get_header_html()
			if self.settings.get_header then
				local header = self.settings:get_header()

				if header then
					local body = { string.format("<h2>%s</h2>", header) }

					if self.error then
						body[#body+1] = "<h3 class='error'>One or more errors occurred, see details in the log</h3>"
					end

					return string.format("<html><head><style>%s</style></head><body>%s</body></html>", html_stylesheet, table.concat(body))
				end
			end
		end

		local function get_footer_html()
			if self.settings.get_header then
				local footer = self.settings:get_footer()

				if footer then
					return string.format("<html><head><style>%s</style></head><body><h3 class='error'>%s</h3></body></html>", html_stylesheet, footer)
				end
			end
		end

		local header_html = get_header_html()
		local footer_html = get_footer_html()

		local controls = ui:VGroup
		{
			Weight = 1,
			StyleSheet = [[
				QTextEdit
				{
					border: none;
				}
			]],

			ui:TextEdit
			{
				ID = "HeaderTextEdit",
				Weight = 0,
				Text = header_html,
				MinimumSize = { 600, 80 },
				ReadOnly = true,
				TextFormat = { RichText = true },
				TextInteractionFlags =  { NoTextInteraction = true },
				Hidden = header_html == nil,
			},

			self.tree,

			ui:TextEdit
			{
				ID = "FooterTextEdit",
				Weight = 0,
				Text = footer_html,
				MinimumSize = { 600, 30 },
				ReadOnly = true,
				TextFormat = { RichText = true },
				TextInteractionFlags =  { NoTextInteraction = true },
				Hidden = footer_html == nil,
			},
		}

		if self.error and self.last_error_item then
			-- Make sure the last error item is visible
			self.tree:ScrollToItem(self.last_error_item)
		end

		return script:show_popup( { WindowTitle = string.format("%s - Log", script.name), FixedSize = { 980, 700 } }, controls, { "Close" })
	end,
}

script.set_declarations()
script:load_settings()
log:initialize(script.log_settings)

local function create_window(media_pool)
	local ui = script.ui
	local dispatcher = script.dispatcher
	local left_column_minimum_size = { 60, 0 }
	local left_column_maximum_size = { 60, 16777215 }
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
			MediaPoolTreeLoadStarted = true,
		},

		FixedSize = { 500, 240 },
		
		ui:VGroup
		{
			Weight = 1,
			Spacing = 10,
			MinimumSize = { 420, 230 },
			MaximumSize = { 16777215, 230 },

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Weight = 0,
					Alignment = { AlignRight = true, AlignVCenter = true },
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
					Text = "Bin"
				},

				ui:ComboBox
				{
					Weight = 1,
					ID = "BinComboBox",
				},

				ui:CheckBox
				{
					Weight = 0,
					ID = "IncludeSubBinsComboBox",
					Text = "Include sub bins",
				},
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Weight = 0,
					Alignment = { AlignRight = true, AlignVCenter = true },
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
					Text = "Mode"
				},

				ui:ComboBox
				{
					Weight = 1,
					ID = "ModeComboBox",
				},
			},

			ui:VGroup
			{
				Weight = 0,
				ID = "StartTimecodeGroup",
				Spacing = 10,

				ui:HGroup
				{
					Weight = 0,

					ui:Label
					{
						Weight = 0,
						ID = "TimecodeLabel",
						Alignment = { AlignRight = true, AlignVCenter = true },
						MinimumSize = left_column_minimum_size,
						MaximumSize = left_column_maximum_size,
						-- Text is set to "Start TC" or "Offset" in update_controls()
					},

					ui:HGroup
					{
						Weight = 1,
						ID = "TimecodeLineEditGroup",

						ui:LineEdit
						{
							ID = "TimecodeLineEdit",
							MinimumSize = { 100, 0 },
							MaximumSize = { 100, 16777215 },
						},

						ui:HGap(0, 1),
					},

					ui:HGroup
					{
						Weight = 0,
						ID = "OffsetFramesGroup",

						ui:SpinBox
						{
							Weight = 0,
							ID = "OffsetFramesSpinBox",
							Minimum = -2147483648,
							Maximum = 2147483647,
							Accelerated = true,
						},

						ui:Label
						{
							Weight = 0,
							Alignment = { AlignLeft = true, AlignVCenter = true },
							Text = "frames",
						},
					},
				},

				ui:HGroup
				{
					Weight = 0,

					ui:Label
					{
						Weight = 0,
						MinimumSize = left_column_minimum_size,
						MaximumSize = left_column_maximum_size,
					},

					ui:CheckBox
					{
						Weight = 0,	
						ID = "CopyOriginalTimecodeCheckBox",
						Text = "Copy original timecode to Audio Start TC metadata",
						ToolTip = "<p>Copy will be performed if the \"Audio TC Type\" and \"Audio Start TC\" metadata fields are empty.</p>",
					},
				},
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Weight = 0,
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
				},

				ui:CheckBox
				{
					Weight = 0,	
					ID = "SkipClipsInUseCheckBox",
					Text = "Skip clips that are in use",
					ToolTip = "<p>Skip clips where the \"Usage\" field is non-zero.</p><p>Clips that aren't audio/video clips are always skipped regardless of this setting.</p>",
				},
			},

			ui:HGroup
			{
				Weight = 0,

				ui:Label
				{
					Weight = 0,
					MinimumSize = left_column_minimum_size,
					MaximumSize = left_column_maximum_size,
				},

				ui:CheckBox
				{
					Weight = 0,	
					ID = "ShowLogCheckBox",
					Text = "Show log",
					ToolTip = "<p>When unchecked, any errors are printed to the console instead.</p>",
				},
			},

			ui:VGap(0, 1),

			ui:HGroup
			{
				Weight = 0,
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

	local function is_valid_timecode()
		local is_valid = window_items.TimecodeLineEdit:HasAcceptableInput()

		if window_items.ModeComboBox.CurrentText == script.constants.MODE.ADD_TIMECODE then
			is_valid = is_valid and window_items.TimecodeLineEdit.Text ~= "+00:00:00:00"
		elseif window_items.ModeComboBox.CurrentText == script.constants.MODE.SUBTRACT_TIMECODE then
			is_valid = is_valid and window_items.TimecodeLineEdit.Text ~= "-00:00:00:00"
		end

		return is_valid
	end

	local function update_controls()
		if window_items.ModeComboBox.CurrentText == script.constants.MODE.SET_TIMECODE
			or window_items.ModeComboBox.CurrentText == script.constants.MODE.ADD_TIMECODE
			or window_items.ModeComboBox.CurrentText == script.constants.MODE.SUBTRACT_TIMECODE
		then
			window_items.TimecodeLabel.Text = "Start TC"
			window_items.TimecodeLineEditGroup.Hidden = false
			window_items.OffsetFramesGroup.Hidden = true

			-- Note: DropFrame timecode with a semicolon in the input mask doesn't work because of a bug in Qt (https://bugreports.qt.io/browse/QTBUG-1588)
			local input_mask = "99:99:99:99"
			
			if window_items.ModeComboBox.CurrentText == script.constants.MODE.SET_TIMECODE then
				window_items.TimecodeLineEdit.InputMask = input_mask
			elseif window_items.ModeComboBox.CurrentText == script.constants.MODE.ADD_TIMECODE then
				window_items.TimecodeLineEdit.InputMask = string.format("+%s", input_mask)
			elseif window_items.ModeComboBox.CurrentText == script.constants.MODE.SUBTRACT_TIMECODE then
				window_items.TimecodeLineEdit.InputMask = string.format("-%s", input_mask)
			end

			window_items.StartButton.Enabled = is_valid_timecode()
		elseif window_items.ModeComboBox.CurrentText == script.constants.MODE.OFFSET_FRAMES then
			window_items.TimecodeLabel.Text = "Offset"
			window_items.TimecodeLineEditGroup.Hidden = true
			window_items.OffsetFramesGroup.Hidden = false

			window_items.StartButton.Enabled = window_items.OffsetFramesSpinBox.Value ~= 0
		elseif window_items.ModeComboBox.CurrentText == script.constants.MODE.RESTORE_FROM_AUDIO_START_TC then
			window_items.StartButton.Enabled = true
		end
		
		window_items.StartTimecodeGroup.Hidden = window_items.ModeComboBox.CurrentText == script.constants.MODE.RESTORE_FROM_AUDIO_START_TC
		window_items.StartButton.Enabled = window_items.StartButton.Enabled and window_items.BinComboBox:Count() > 0

		window:RecalcLayout()
	end

	local function initialize_controls()
		window.StyleSheet = [[
			QComboBox
			{
				min-height: 18px;
				max-height: 18px;
			}
		]]

		window_items.IncludeSubBinsComboBox.Checked = script.settings.include_sub_bins

		window_items.ModeComboBox:AddItems
		{
			script.constants.MODE.SET_TIMECODE,
			script.constants.MODE.ADD_TIMECODE,
			script.constants.MODE.SUBTRACT_TIMECODE,
			script.constants.MODE.OFFSET_FRAMES,
			script.constants.MODE.RESTORE_FROM_AUDIO_START_TC,
		}

		window_items.ModeComboBox.CurrentText = script.settings.mode
		window_items.TimecodeLineEdit.Text = script.settings.timecode
		window_items.OffsetFramesSpinBox.Value = script.settings.offset_frames
		window_items.CopyOriginalTimecodeCheckBox.Checked = script.settings.copy_original_tc
		window_items.SkipClipsInUseCheckBox.Checked = script.settings.skip_clips_in_use
		window_items.ShowLogCheckBox.Checked = script.settings.show_log

		update_controls()

		-- Lock controls while we're enumerating bins
		window_items.BinComboBox.Editable = true
		window_items.BinComboBox.LineEdit.PlaceholderText = "Please wait. Enumerating Media Pool Bins..."
		window_items.BinComboBox.Enabled = false
		window_items.StartButton.Enabled = false

		-- Start enumerating bins as a queued event, this way execution isn't blocked and ultimately the GUI is shown before bins are loaded.
		-- Events queued after this, like clicking a button, are blocked until this event has completed.
		script.ui:QueueEvent(window._window, "MediaPoolTreeLoadStarted", { media_pool = media_pool } )
	end

	initialize_controls()

	window.On[script.window_id].MediaPoolTreeLoadStarted = function(ev)
		script.media_pool.tree = luaresolve:get_media_pool_tree(ev.media_pool)
		
		window_items.BinComboBox.Editable = false
		
		for index, folder_info in ipairs(script.media_pool.tree.folder_info_by_branch) do
			window_items.BinComboBox:AddItem(folder_info.path)
		
			if folder_info.unique_id == script.media_pool.tree.current.unique_id then
				window_items.BinComboBox.CurrentIndex = index - 1
			end
		end
		
		window_items.BinComboBox.Enabled = true
		window_items.StartButton.Enabled = true

		update_controls()
	end

	window.On.TimecodeLineEdit.TextChanged = function(ev)
		window_items.StartButton.Enabled = is_valid_timecode() and window_items.BinComboBox:Count() > 0
	end

	window.On.OffsetFramesSpinBox.ValueChanged = function(ev)
		window_items.StartButton.Enabled = ev.Value ~= 0 and window_items.BinComboBox:Count() > 0
	end

	window.On.ModeComboBox.CurrentIndexChanged = function(ev)
		update_controls()
	end

	window.On.CancelButton.Clicked = function(ev)
		dispatcher:ExitLoop(nil)
	end

	window.On.StartButton.Clicked = function(ev)
		script.settings.include_sub_bins = window_items.IncludeSubBinsComboBox.Checked
		script.settings.mode = window_items.ModeComboBox.CurrentText
		script.settings.skip_clips_in_use = window_items.SkipClipsInUseCheckBox.Checked
		script.settings.show_log = window_items.ShowLogCheckBox.Checked

		if window_items.ModeComboBox.CurrentText ~= script.constants.MODE.RESTORE_FROM_AUDIO_START_TC then
			script.settings.copy_original_tc = window_items.CopyOriginalTimecodeCheckBox.Checked

			if window_items.ModeComboBox.CurrentText == script.constants.MODE.OFFSET_FRAMES then
				script.settings.offset_frames = window_items.OffsetFramesSpinBox.Value
			else
				script.settings.timecode = window_items.TimecodeLineEdit.Text
			end
		end

		script:save_settings()

		dispatcher:ExitLoop(script.media_pool.tree.folder_info_by_branch[window_items.BinComboBox.CurrentIndex + 1].folder)
	end
	
	window.On[script.window_id].Close = function(ev)
		window_items.CancelButton:Click()
	end

	return window, window_items
end

local function set_timecode_for_media_pool_clips(folder)
	local folder_tree = script.media_pool.tree.folder_info_by_unique_id[folder:GetUniqueId()]
	local index = 0
	local log_entry_metatable =
	{
		__tostring = function(self)
			return string.format("%s, %s/%s", self.status, self.bin, self.clip_name)
		end,
	}

	if script.settings.include_sub_bins then
		if folder_tree.is_root then
			log.total_item_count = folder_tree.total_item_count
		else
			log.total_item_count = folder_tree:get_recursive_item_count()
		end
	else
		log.total_item_count = #folder_tree.media_pool_items
	end

	local function get_timecode(media_pool_item_info)
		local tc = script.settings.timecode

		-- If the clip uses drop frame timecode we want to ensure there's a semicolon used as the seconds/frames separator
		if media_pool_item_info.drop_frame == "1" then
			local frame_separator_position = tc:find("[:;]%d+$")
			tc = string.format("%s;%s", tc:sub(1, frame_separator_position - 1), tc:sub(frame_separator_position + 1))
		end

		if script.settings.mode == script.constants.MODE.SET_TIMECODE then
			return tc
		else
			local original_start_frame = luaresolve:frame_from_timecode(media_pool_item_info.start_tc, media_pool_item_info.fps)
			local offset_frames

			if script.settings.mode == script.constants.MODE.OFFSET_FRAMES then
				offset_frames = script.settings.offset_frames
			else
				offset_frames = luaresolve:frame_from_timecode(tc:sub(2), media_pool_item_info.fps)
				offset_frames = iif(script.settings.mode == script.constants.MODE.SUBTRACT_TIMECODE, -offset_frames, offset_frames)
			end

			local new_start_frame = original_start_frame + offset_frames

			if new_start_frame < 0 then
				return nil, "Negative timecode is not supported"
			end

			return luaresolve:timecode_from_frame(new_start_frame, media_pool_item_info.fps, media_pool_item_info.drop_frame)
		end
	end

	local function set_timecode(media_pool_item_info, log_entry, audio_tc_type, audio_start_tc)
		local timecode, error_message = get_timecode(media_pool_item_info)

		if timecode == nil then
			log_entry.status = string.format("Warning: %s", error_message)
			log_entry.status_code = "warning"
			return true
		end

		if media_pool_item_info.start_tc ~= timecode then
			local success, error_message, timeout_action = luaresolve.set_clip_property(media_pool_item_info.media_pool_item, "Start TC", timecode)

			if success then
				log_entry.new_start_tc = timecode

				if media_pool_item_info.usage ~= "0" then
					log_entry.status = "Warning: Clip was in use"
					log_entry.status_code = "warning"
				end
					
				if (audio_tc_type == nil or #audio_tc_type == 0) and (audio_start_tc == nil or #audio_start_tc == 0) then
					media_pool_item_info.media_pool_item:SetMetadata
					{
						["Audio TC Type"] = script.constants.METADATA_VALUES.ORIGINAL_TC,
						["Audio Start TC"] = media_pool_item_info.start_tc, -- start_tc contains the existing Start TC, before it was updated
					}
				end

				media_pool_item_info.start_tc = timecode
				log.updated_items = log.updated_items + 1
			else
				log_entry.status = string.format("Error: %s", error_message)
				log_entry.status_code = "error"
			end

			return success, error_message, timeout_action
		else
			log_entry.status = "Skipped"
			log_entry.status_code = "skipped"

			return true
		end
	end

	local function restore_timecode(media_pool_item_info, log_entry, audio_tc_type, audio_start_tc)
		if audio_tc_type == script.constants.METADATA_VALUES.ORIGINAL_TC and audio_start_tc ~= nil and #audio_start_tc > 0 then
			if media_pool_item_info.start_tc ~= audio_start_tc then
				local success, error_message, timeout_action = luaresolve.set_clip_property(media_pool_item_info.media_pool_item, "Start TC", audio_start_tc)

				if success then
					log_entry.new_start_tc = audio_start_tc
				
					if media_pool_item_info.usage ~= "0" then
						log_entry.status = "Warning: Clip was in use"
						log_entry.status_code = "warning"
					end

					media_pool_item_info.start_tc = audio_start_tc
					log.updated_items = log.updated_items + 1
				else
					log_entry.status = string.format("Error: %s", error_message)
					log_entry.status_code = "error"
				end

				return success, error_message, timeout_action
			else
				log_entry.status = "Skipped"
				log_entry.status_code = "skipped"

				return true
			end
		else
			log_entry.status = "Warning: Original timecode not found"
			log_entry.status_code = "warning"

			return true -- We're not considering this an error
		end
	end

	local function set_media_pool_clip_timecode(media_pool_item_info)
		index = index + 1
		script:update_progress("ProgressUpdated", { Progress = 100 * (index / log.total_item_count), Status = "Clip "..tostring(index) } )
		local success = true
		local timeout_action = "stop"

		-- Template for the log entry that we will put in the log
		local log_entry = 
		{
			index = index,
			bin = media_pool_item_info.folder.path,
			clip_name = media_pool_item_info.clip_name,
			type = media_pool_item_info.type,
			start_tc = media_pool_item_info.start_tc,
			new_start_tc = media_pool_item_info.start_tc,
			status = "OK",
			status_code = "ok",
		}

		setmetatable(log_entry, log_entry_metatable)

		-- Note: To determine the type of the clip we can't use the clip property "Type" as that's a translated property
		--       and will return text translated to the language Resolve is currently set to.
		--       We'll use "Format" instead to make sure it's a clip from disk and not a compound/timeline/multicam/generated clip.
		if #media_pool_item_info.format > 0 and ((script.settings.skip_clips_in_use == true and media_pool_item_info.usage == "0") or script.settings.skip_clips_in_use == false) then
			-- Cache the metadata we will need
			local clip_metadata = media_pool_item_info.media_pool_item:GetMetadata()
			local audio_tc_type = clip_metadata["Audio TC Type"]
			local audio_start_tc = clip_metadata["Audio Start TC"]

			if script.settings.mode == script.constants.MODE.RESTORE_FROM_AUDIO_START_TC then
				success, _, timeout_action = restore_timecode(media_pool_item_info, log_entry, audio_tc_type, audio_start_tc)
			else
				success, _, timeout_action = set_timecode(media_pool_item_info, log_entry, audio_tc_type, audio_start_tc)
			end
		else
			log_entry.status = "Skipped"
			log_entry.status_code = "skipped"
		end

		if script.settings.show_log then
			log:write(log_entry)
		end

		if not success then
			log.error = true

			if not script.settings.show_log then
				printerr(tostring(log_entry).."\n")
			end

			if timeout_action == "stop" then
				return false -- Stops traversing the media pool
			end
		elseif not script.settings.show_log and log_entry.status_code == "warning" then
			print(tostring(log_entry).."\n")
		end
	end

	local progress_header = ""

	if script.settings.mode == script.constants.MODE.RESTORE_FROM_AUDIO_START_TC then
		progress_header = "Restoring Timecode from Metadata"
	elseif script.settings.mode == script.constants.MODE.OFFSET_FRAMES then
		progress_header = string.format("Setting Timecode to %s frame%s", iif(script.settings.offset_frames < 0, tostring(script.settings.offset_frames), "+"..tostring(script.settings.offset_frames)), iif(script.settings.offset_frames == 1, "", "s"))
	else
		progress_header = string.format("Setting Timecode to %s", script.settings.timecode)
	end

	script:create_progress_window(progress_header)
	script.progress_window:Show()

	folder_tree:traverse_by_branch
	{
		folder_function = function(folder_info)
			if script.settings.include_sub_bins == false then
				-- Only process the first folder_info, then stop
				return false
			end
		end,

		media_pool_item_function = set_media_pool_clip_timecode,

		-- Only sort the media pool items if we're showing the log
		media_pool_item_sort_function = iif(not script.settings.show_log, nil, function(a, b)
			return a.clip_name < b.clip_name
		end),
	}

	script.dispatcher:ExitLoop()
	script.progress_window:Hide()
end

local function main()
	local project = assert(resolve:GetProjectManager():GetCurrentProject(), "Couldn't get current project")
	local media_pool = project:GetMediaPool()
	local window = create_window(media_pool)

	window:Show()
	local selected_folder = script.dispatcher:RunLoop()
	window:Hide()

	if selected_folder then
		-- Note: MediaPoolItem:SetClipProperty("Start TC", "00:00:00:00") fails silently if the clip is currently showing
		--       in the viewer on the Media, Cut or Edit pages while it's showing any other frame than the first frame.
		--       As a workaround we switch to the Deliver page while the script is running.
		--       This also has a significant positive impact on the overall speed of changing clip properties since the Deliver
		--       page isn't showing the media pool and doesn't need to reload the list of clips for each change.
		local initial_page = resolve:GetCurrentPage()
		resolve:OpenPage("deliver")

		set_timecode_for_media_pool_clips(selected_folder)
		
		media_pool:SetCurrentFolder(selected_folder)
		resolve:OpenPage(initial_page)

		if script.settings.show_log then
			log:show()
		end
	end
end

main()
