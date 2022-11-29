local script, luaresolve, libavutil

script = 
{
    filename = debug.getinfo(1,"S").source:match("^.*%@(.*)"),
    version = "1.0",
    name = "Grab Stills at Markers",
	window_id = "GrabStills",

   	settings =
	{
        markers = "Any",
		export = false,
        export_to = "",
		format = "jpg",
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

    stills = 
    {
        formats = 
        {
            dpx = "DPX Files (*.dpx)",
            cin = "Cineon Files (*.cin)",
            tif = "TIFF Files (*.tif)",
            jpg = "JPEG Files (*.jpg)",
            png = "PNG Files (*.png)",
            ppm = "PPM Files (*.ppm)",
            bmp = "BMP Files (*.bmp)",
            xpm = "XPM Files (*.xpm)",

            sort_order = table.pack("dpx", "cin", "tif", "jpg", "png", "ppm", "bmp", "xpm")
        },

        -- Workaround for an error that occurs during ExportStills() if the "Timelines" album is selected by the user (verified in v18.1)
        reselect_album = function(album, gallery)
            for _, gallery_album in ipairs(gallery:GetGalleryStillAlbums()) do
                if gallery_album ~= album then
                    gallery:SetCurrentStillAlbum(gallery_album)
                    break
                end
            end

            gallery:SetCurrentStillAlbum(album)
            return album
        end,
    },

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

local function create_window(marker_count_by_color, still_album_name)
    local ui = script.ui
	local dispatcher = script.dispatcher

    local left_column_minimum_size = { 100, 0 }
    local left_column_maximum_size = { 100, 16777215 }

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

		FixedSize = { 600, 250 },

        ui:VGroup
        {
            MinimumSize = { 450, 230 },
            MaximumSize = { 16777215, 230 },

			Weight = 1,

            ui:HGroup
            {
                Weight = 0,
                Spacing = 10,

                ui:Label
                {
                    Weight = 0,
                    Alignment = { AlignRight = true, AlignVCenter = true },
                    MinimumSize = left_column_minimum_size,
                    MaximumSize = left_column_maximum_size,
                    Text = "Timeline markers"
                },

                ui:ComboBox
			    {
				    Weight = 1,
				    ID = "MarkersComboBox",
			    },
            },
			
            ui:HGroup
            {
                Weight = 0,
                Spacing = 10,

                ui:Label
                {
                    Weight = 0,
                    MinimumSize = left_column_minimum_size,
                    MaximumSize = left_column_maximum_size,
                },

                ui:Label
			    {
				    Weight = 1,
                    ID = "InfoLabel",
			    },
            },

            ui:VGap(10),

            ui:HGroup
            {
                Weight = 0,
                Spacing = 10,

                ui:Label
                {
                    Weight = 0,
                    MinimumSize = left_column_minimum_size,
                    MaximumSize = left_column_maximum_size,
                },

                ui:CheckBox
			    {
				    Weight = 1,
				    ID = "ExportCheckBox",
                    Text = "Export grabbed stills",
                    Checked = script.settings.export,
                    Events = { Toggled = true },
			    },
            },

            ui:VGroup
            {
                ID = "ExportSettings",
                Weight = 0,
                Enabled = script.settings.export,

                ui:HGroup
                {
                    Weight = 0,
                    Spacing = 10,
                    
                    ui:Label
                    {
                        Weight = 0,
                        Alignment = { AlignRight = true, AlignVCenter = true },
                        MinimumSize = left_column_minimum_size,
                        MaximumSize = left_column_maximum_size,
                        Text = "Export to",
                    },

                    ui:LineEdit
			        {
				        Weight = 1,
				        ID = "ExportToLineEdit",
                        Text = script.settings.export_to,
			        },
                    
                    ui:Button
                    {
                        Weight = 0,
                        ID = "BrowseButton",
                        Text = "Browse",
                    },
                },

                ui:HGroup
                {
                    Weight = 0,
                    Spacing = 10,

                    ui:Label
                    {
                        Weight = 0,
                        Alignment = { AlignRight = true, AlignVCenter = true },
                        MinimumSize = left_column_minimum_size,
                        MaximumSize = left_column_maximum_size,
                        Text = "Format",
                    },

                    ui:ComboBox
			        {
				        Weight = 1,
				        ID = "FormatComboBox",
			        },
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
                },

                ui:Button
                {
                    Weight = 0,
                    ID = "StartButton",
                    Text = "Start",
                    Default = true,
                },
            },
        },
    })

    window_items = window:GetItems()

    local function update_controls()
        local start_button_enabled = not window_items.ExportCheckBox.Checked or (window_items.ExportCheckBox.Checked and #window_items.ExportToLineEdit.Text > 0)
        window_items.ExportSettings.Enabled = window_items.ExportCheckBox.Checked

        local marker_count = marker_count_by_color[window_items.MarkersComboBox.CurrentText]

        if marker_count ~= nil and marker_count > 0 then
            window_items.InfoLabel.Text = string.format("%s still%s will be grabbed to the \"%s\" album", marker_count, iif(marker_count == 1, "", "s"), still_album_name)
        else
            local marker_color = iif(window_items.MarkersComboBox.CurrentText == "Any", "", window_items.MarkersComboBox.CurrentText:lower().." ")
            window_items.InfoLabel.Text = string.format("No %smarkers found, no stills will be grabbed", marker_color)
            start_button_enabled = false
        end

        window_items.StartButton.Enabled = start_button_enabled
        window_items.ExportToLineEdit.ToolTip = window_items.ExportToLineEdit.Text
    end

    local function initialize_controls()
        local right_column_button_width = 70 -- excluding border

        window.StyleSheet = [[
            QComboBox
            {
                margin-right: ]]..(right_column_button_width + 2 + 10)..[[px;
                padding-right: 6px;
                padding-left: 6px;
                min-height: 18px;
                max-height: 18px;
            }

            QLineEdit
            {
                padding-top: 0px;
                margin-top: 1px;
                min-height: 18px;
                max-height: 18px;
            }

            QPushButton
            {
                min-height: 20px;
                max-height: 20px;
                min-width: ]]..right_column_button_width..[[px;
                max-width: ]]..right_column_button_width..[[px;
            }
        ]]

        window_items.MarkersComboBox:AddItem("Any")
        window_items.MarkersComboBox:AddItems(luaresolve.markers.colors)
        window_items.MarkersComboBox:InsertSeparator(1)
        window_items.MarkersComboBox.CurrentText = script.settings.markers

        for _, format in ipairs(luaresolve.stills.formats.sort_order) do
            window_items.FormatComboBox:AddItem(luaresolve.stills.formats[format])
        end

        window_items.FormatComboBox.CurrentText = luaresolve.stills.formats[script.settings.format]
        
        update_controls()
    end

    initialize_controls()

    window.On.MarkersComboBox.CurrentIndexChanged = function(ev)
        update_controls()
    end

    window.On.ExportCheckBox.Toggled = function(ev)
        update_controls()
    end

    window.On.BrowseButton.Clicked = function(ev)
        local selected_dir = fusion:RequestDir(window_items.ExportToLineEdit.Text, { FReqS_Title = "Export to", })

        if selected_dir then
            window_items.ExportToLineEdit.Text = selected_dir
        end
    end

    window.On.ExportToLineEdit.TextChanged = function(ev)
        update_controls()
    end

    window.On.CancelButton.Clicked = function(ev)
        dispatcher:ExitLoop(false)
    end

    window.On.StartButton.Clicked = function(ev)
        script.settings.markers = window_items.MarkersComboBox.CurrentText
		script.settings.export = window_items.ExportCheckBox.Checked
        script.settings.export_to = window_items.ExportToLineEdit.Text
		script.settings.format = luaresolve.stills.formats.sort_order[window_items.FormatComboBox.CurrentIndex + 1]
        script:save_settings()

        dispatcher:ExitLoop(true)
    end
	
    window.On[script.window_id].KeyPress = function(ev)
		if (ev.Key == 16777216) then -- Escape
			window_items.CancelButton:Click()
		end
	end

    window.On[script.window_id].Close = function(ev)
        window_items.CancelButton:Click()
    end

    return window
end

local function main()
    local project = assert(resolve:GetProjectManager():GetCurrentProject(), "Couldn't get current project")
    local gallery = assert(project:GetGallery(), "Couldn't get the Resolve stills gallery")
    local still_album = assert(gallery:GetCurrentStillAlbum(), "Couldn't get the current gallery still album") 
    local still_album_name = gallery:GetAlbumName(still_album)
    local timeline = assert(project:GetCurrentTimeline(), "Couldn't get current timeline")
    local timeline_start = timeline:GetStartFrame()
    local frame_rate = timeline:GetSetting("timelineFrameRate")
    local drop_frame = timeline:GetSetting("timelineDropFrameTimecode")
    local markers = timeline:GetMarkers()

    if next(markers) ~= nil then
        local marker_count_by_color = luaresolve.markers.get_marker_count_by_color(markers)
	    local window = create_window(marker_count_by_color, still_album_name)

        window:Show()
	    local grab_stills = script.dispatcher:RunLoop()
        window:Hide()

        if grab_stills then
            local initial_state = luaresolve.change_page("color")
            local stills_to_export = {}

            -- Note: The script will stop if an automated backup starts, or if the user does something in Resolve like opening Preferences or Project Settings.
            --       Resolve currently has no way of locking the user interface while running a script and we can't move the playhead if we have a modal window showing.

            for marker_frame, marker in pairs(markers) do
                if script.settings.markers == "Any" or script.settings.markers == marker.color then
	                local frame = timeline_start + marker_frame
                    local timecode = luaresolve:timecode_from_frame(frame, frame_rate, drop_frame)
	                
                    assert(timeline:SetCurrentTimecode(timecode), "Couldn't navigate to marker at "..timecode)
                    stills_to_export[#stills_to_export+1] = assert(timeline:GrabStill(), "Couldn't grab still at "..timecode)
                end
            end
            
            if script.settings.export then
                local prefix = "" -- An empty prefix lets it export using the labels configured in Resolve
                
                luaresolve.stills.reselect_album(still_album, gallery)
                assert(still_album:ExportStills(stills_to_export, script.settings.export_to, prefix, script.settings.format), "An error occurred while exporting stills")
            end

            luaresolve.restore_page(initial_state)
        end
    end
end

main()
