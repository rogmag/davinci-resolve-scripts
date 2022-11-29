--[[
	DaVinci Resolve comes with binaries for libavcodec, libavformat and libavutil.

	This script is an example of how we can take advantage of having those libraries available to LuaJIT.

	roger.magnusson@gmail.com
]]

local luaresolve, libavutil

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
	end
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

libavutil.set_declarations()

--[[
	Usage:

	luaresolve:frame_from_timecode(string Timecode, number FrameRate)

	luaresolve:timecode_from_frame(number Frame, number FrameRate [, boolean DropFrame])
]]

print(luaresolve:frame_from_timecode("01:00:00;00", 29.97))
print(luaresolve:frame_from_timecode("01:00:00:00", 25))
print(luaresolve:timecode_from_frame(107892, 29.97, true))
print(luaresolve:timecode_from_frame(90000, 25))
