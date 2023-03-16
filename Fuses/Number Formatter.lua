FuRegisterClass("NumberFormatter", CT_Modifier,
{
	REGS_Name = "Number Formatter",
	REGS_OpIconString = "NumberFormatter",
	REGS_OpDescription = "Formats a number with leading zeros, thousands separator and more",

	REGID_DataType = "Text",
	REG_Fuse_NoEdit = true,
	REG_Fuse_NoReload = true,
	REG_Fuse_NoJIT = true,
	REG_NoPreCalcProcess = true,
})

local thousands_separators = table.pack
(
	{ Name = "None", Value = "", },
	{ Name = "Comma", Value = "," },
	{ Name = "Period", Value = "." },
	{ Name = "Thin Space", Value = " " }, -- Unicode: U+2009, this is the standard and recommended space separator character, not the normal space character
	{ Name = "Space", Value = " " },
	{ Name = "Underscore", Value = "_" },
	{ Name = "Apostrophe", Value = "'" }
)

local decimal_separators = table.pack
(
	{ Name = "Period", Value = "." },
	{ Name = "Comma", Value = "," }
)

function Create()
	in_prefix = self:AddInput("Prefix", "Prefix",
	{
		LINKID_DataType = "Text",
		INPID_InputControl = "TextEditControl",
		TEC_Lines = 1,
	})

	in_value = self:AddInput("Value", "Value",
	{
		LINKID_DataType = "Number",
		INPID_InputControl = "SliderControl",
		LINK_Main = 1,
		INP_MinScale = 0,
		INP_MaxScale = 10000,
		INP_MinAllowed = -9.999999e+29,
		INP_MaxAllowed = 9.999999e+29,
	})
	
	in_suffix = self:AddInput("Suffix", "Suffix",
	{
		LINKID_DataType = "Text",
		INPID_InputControl = "TextEditControl",
		TEC_Lines = 1,
	})

	in_decimal_separator = self:AddInput("Decimal Separator", "DecimalSeparator",
	{
		LINKID_DataType = "Number",
		INPID_InputControl = "ComboControl",
		{ CCS_AddString = decimal_separators[1].Name },
		{ CCS_AddString = decimal_separators[2].Name },
	})

	in_decimals = self:AddInput("Decimals", "Decimals",
	{
		LINKID_DataType = "Number",
		INPID_InputControl = "SliderControl",
		INP_Integer = true,
		INP_MinScale = 0,
		INP_MaxScale = 6,
		INP_MinAllowed = 0,
		INP_MaxAllowed = 30,

		-- Set this to true to also control the precision of the in_value input from this input.
		-- The downside of enabling this is that the number of decimals has the be set by the user
		-- before entering decimal values in the in_value input, otherwise they won't register.
		INP_DoNotifyChanged = false,
	})

	in_characters = self:AddInput("Minimum Characters", "MinimumCharacters",
	{
		LINKID_DataType = "Number",
		INPID_InputControl = "SliderControl",
		INP_Integer = true,
		INP_MinScale = 1,
		INP_MaxScale = 16,
		INP_MinAllowed = 1,
		INP_MaxAllowed = 60,
	})

	in_thousands_separator = self:AddInput("Thousands Separator", "ThousandsSeparator",
	{
		LINKID_DataType = "Number",
		INPID_InputControl = "ComboControl",
		{ CCS_AddString = thousands_separators[1].Name },
		{ CCS_AddString = thousands_separators[2].Name },
		{ CCS_AddString = thousands_separators[3].Name },
		{ CCS_AddString = thousands_separators[4].Name },
		{ CCS_AddString = thousands_separators[5].Name },
		{ CCS_AddString = thousands_separators[6].Name },
		{ CCS_AddString = thousands_separators[7].Name },
	})
	
	out_value = self:AddOutput("Output", "Output",
	{
		LINKID_DataType = "Text",
		LINK_Main = 1,
	})
end

function NotifyChanged(input, parameter, time)
	if input ~= nil and input == in_decimals and parameter ~= nil then
		-- Set the precision of the in_value input to match the number of decimals selected by the user.
		-- Note: This is disabled by default since INP_DoNotifyChanged is set to false for in_decimals.
		in_value:SetAttrs
		{
			IC_DisplayedPrecision = parameter.Value
		}
	end
end

function Process(req)
	local value = in_value:GetValue(req).Value
	local prefix = in_prefix:GetValue(req).Value
	local suffix = in_suffix:GetValue(req).Value
	
	local number =
	{
		value = value,
		sign = iif(value < 0, "-", ""),
		decimal_count = in_decimals:GetValue(req).Value,
		decimal_separator = decimal_separators[in_decimal_separator:GetValue(req).Value+1].Value,
		thousands_separator = thousands_separators[in_thousands_separator:GetValue(req).Value+1].Value,
		minimum_character_count = in_characters:GetValue(req).Value,
	}

	setmetatable(number,
	{
		__tostring = function(self)
			local escape_patterns = function(str)
				-- Escape characters that are otherwise used for pattern matching in string.gsub()
				return (str:gsub(".",
				{
					["^"] = "%^",
					["$"] = "%$",
					["("] = "%(",
					[")"] = "%)",
					["%"] = "%%",
					["."] = "%.",
					["["] = "%[",
					["]"] = "%]",
					["*"] = "%*",
					["+"] = "%+",
					["-"] = "%-",
					["?"] = "%?",
					["\0"] = "%z",
				}))
			end

			local function add_thousands_separator(str, is_decimal)
				local escaped_str = escape_patterns(str)
				local escaped_separator = escape_patterns(self.thousands_separator)
				local placeholder = "__separator__"

				if not is_decimal then
					return escaped_str:reverse():gsub("%d%d%d", "%1"..placeholder):reverse():gsub("^"..placeholder:reverse(), ""):gsub(placeholder:reverse(), escaped_separator)
				else
					return escaped_str:gsub("%d%d%d", "%1"..placeholder):gsub(placeholder.."$", ""):gsub(placeholder, escaped_separator)
				end
			end

			local number_format = string.format("%%0%s.%sf", self.minimum_character_count, self.decimal_count)

			local number_string = string.format(number_format, self.value)
			local integer_string = string.match(number_string, "(%d+)")
			local decimal_separator = iif(self.decimal_count > 0, self.decimal_separator, "")
			local decimal_string = iif(self.decimal_count > 0, string.match(number_string, "%.(%d+)$"), "")

			if #self.thousands_separator > 0 then
				return string.format("%s%s%s%s", self.sign, add_thousands_separator(integer_string), decimal_separator, add_thousands_separator(decimal_string, true))
			else
				return string.format("%s%s%s%s", self.sign, integer_string, decimal_separator, decimal_string)
			end
		end
	})

	out_value:Set(req, Text(string.format("%s%s%s", prefix, number, suffix)))
end
