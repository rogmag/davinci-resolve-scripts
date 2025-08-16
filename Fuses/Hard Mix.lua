--[[

MIT License

Copyright (c) 2025 Roger Magnusson

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


	This is a port to DCTL of Simon Ubsdell's hard mix macro: https://www.youtube.com/watch?v=pCjr0IyGoKc

	The Fuse will run in real-time on the GPU, so you'll likely want to disable memory cache in Fusion/Resolve,
	as caching will inevitably run out of VRAM and start copying to normal RAM, which will make it slow.

	roger.magnusson@gmail.com


]]

FuRegisterClass("HardMix", CT_Tool,
{
	REGS_Name = "Hard Mix",
	REGS_OpIconString = "HM",
	REGS_OpDescription = "Merge using a Hard Mix blend mode",

	REGS_Category = "Composite",

	REG_Fuse_NoEdit = true,
	REG_Fuse_NoReload = true,

	REG_NoBlendCtrls = true, -- Disable the built-in CPU blend, we'll run our own on the GPU
})

DCTL =
{
	HardMix =
	{
		Params =
		[[
			float fill;
			int   curve_type;      // 0: smoothstep, 1: smootherstep
			float curve_blend;
			bool  blend_with_fill;
			float blend;
			bool  clamp_coverage;
			int   dstsize[2];
		]],

		Kernel =
		[[
			__DEVICE__ float4 Merge(float4 bg, float4 fg, float blend, bool clamp_coverage)
			{
				if (blend == 0.0f)
				{
					return bg;
				}
				else
				{
					float fg_alpha = fg.w;

					if (clamp_coverage)
					{
						// Clamp foreground alpha to [0, 1]
						fg_alpha = _saturatef(fg_alpha);
					}

					// Additive over
					float4 merged = fg + bg * (1.0f - fg_alpha);

					// Blend between the background and the merged result
					return _mix(bg, merged, blend);
				}
			}

			__DEVICE__ float3 smootherstep(float3 t)
			{
				return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
			}

			__KERNEL__ void HardMixKernel(__CONSTANTREF__ HardMixParams *params, __TEXTURE2D__ src_bg, __TEXTURE2D__ src_fg, __TEXTURE2D_WRITE__ dst)
			{
				DEFINE_KERNEL_ITERATORS_XY(x, y);

				if (x >= params->dstsize[0] || y >= params->dstsize[1]) return;

				const float fill = params->fill;

				// Read the background and foreground pixels
				const float4 bg_rgba = _tex2DVec4(src_bg, x, y);
				const float4 fg_rgba = _tex2DVec4(src_fg, x, y);
	
				// Compute the average color based on the fill factor
				float3 average = (to_float3(bg_rgba.x, bg_rgba.y, bg_rgba.z) * (2.0f - fill) + to_float3(fg_rgba.x, fg_rgba.y, fg_rgba.z) * fill) * 0.5f;

				// Normalize to the [0, 1] range
				float3 normalized = (average - fill * 0.5f) / _fmaxf(1.0f - fill, 1e-6f); // Epsilon to prevent division by zero
				
				// Clamp the normalized values to [0, 1]
				normalized.x = _saturatef(normalized.x);
				normalized.y = _saturatef(normalized.y);
				normalized.z = _saturatef(normalized.z);

				float3 curved;

				if (params->curve_type == 0) // smoothstep
				{
					curved.x = smoothstep(0.0f, 1.0f, normalized.x);
					curved.y = smoothstep(0.0f, 1.0f, normalized.y);
					curved.z = smoothstep(0.0f, 1.0f, normalized.z);
				}
				else if (params->curve_type == 1) // smootherstep
				{
					curved = smootherstep(normalized);
				}
				else // No curve applied
				{
					curved = normalized;
				}

				if (params->blend_with_fill)
				{
					// If blending with fill, apply the fill factor to the curved result
					curved = _mix(normalized, curved, fill);
				}

				float3 curve_blended = _mix(normalized, curved, params->curve_blend);

				float4 merged = Merge(
					bg_rgba,
					to_float4(curve_blended.x, curve_blended.y, curve_blended.z, bg_rgba.w),
					params->blend,
					params->clamp_coverage
				);

				// Write the merged result to the destination texture
				_tex2DVec4Write(dst, x, y, merged);
			}
		]],
	},
}

function Create()
	InFill = self:AddInput("Fill", "Fill", {
		LINKID_DataType = "Number",
		INPID_InputControl = "SliderControl",
		INP_MinAllowed = 0.0,
		INP_MaxAllowed = 1.0,
		INP_MinScale = 0.0,
		INP_MaxScale = 1.0,
		INP_Default = 0.5,

		-- Disable curve controls when fill is 1.0
		INPS_ExecuteOnChange = [=[
			local disabled = self[CurrentTime] == 1.0
			tool.Curve:SetAttrs({ INPB_Disabled = disabled })
			tool.CurveBlend:SetAttrs({ INPB_Disabled = disabled })
			tool.BlendWithFill:SetAttrs({ INPB_Disabled = disabled })
		]=],
	})

	InCurveNest = self:BeginControlNest("Curve", "CurveNest", true)

	InCurve = self:AddInput("Curve", "Curve", {
		LINKID_DataType = "Number",
		INPID_InputControl = "ComboControl",
		{ CCS_AddString = "Smoothstep", },
		{ CCS_AddString = "Smootherstep", },
		INP_Integer = true,
		INP_Default = 1.0, -- Smootherstep
	})

	InCurveBlend = self:AddInput("Curve Blend", "CurveBlend",
	{
		LINKID_DataType = "Number",
		INPID_InputControl = "SliderControl",
		INP_MinAllowed = 0.0,
		INP_MaxAllowed = 1.0,
		INP_MinScale = 0.0,
		INP_MaxScale = 1.0,
		INP_Default = 1.0,
		SLCS_LowName = "Linear",
		SLCS_HighName = "Curve",
	})

	InBlendWithFill = self:AddInput("Blend with Fill", "BlendWithFill",
	{
		LINKID_DataType = "Number",
		INPID_InputControl = "CheckboxControl",
		INP_Integer = true,
		INP_Default = 1.0,
	})

	self:EndControlNest()

	self:BeginControlNest("Merge", "MergeNest", true)

	InBlend = self:AddInput("Blend", "Blend",
	{
		LINKID_DataType = "Number",
		INPID_InputControl = "SliderControl",
		INP_MinAllowed = 0.0,
		INP_MaxAllowed = 1.0,
		INP_MinScale = 0.0,
		INP_MaxScale = 1.0,
		INP_Default = 1.0,
	})

	InClampCoverage = self:AddInput("Clamp Coverage", "ClampCoverage",
	{
		LINKID_DataType = "Number",
		INPID_InputControl = "CheckboxControl",
		INP_Integer = true,
		INP_Default = 1.0,
	})

	self:EndControlNest()

	InImageBG = self:AddInput("Background", "Background",
	{
		LINKID_DataType = "Image",
		LINK_Main = 1,
		INP_Required = true,
		INP_AcceptsGPUImages = true,
	})
	
	InImageFG = self:AddInput("Foreground", "Foreground",
	{
		LINKID_DataType = "Image",
		LINK_Main = 2,
		INP_Required = true,
		INP_AcceptsGPUImages = true,
	})

	OutImage = self:AddOutput("Output", "Output",
	{
		LINKID_DataType = "Image",
		LINK_Main = 1,
	})
end

local function render_hard_mix(req, bg_img, fg_img)
	local isPreCalc = req:IsPreCalc()

	local fill = InFill:GetValue(req).Value
	local curve_type = InCurve:GetValue(req).Value
	local curve_blend = InCurveBlend:GetValue(req).Value
	local blend_with_fill = InBlendWithFill:GetValue(req).Value == 1.0
	local blend = InBlend:GetValue(req).Value
	local clamp_coverage = InClampCoverage:GetValue(req).Value == 1.0

	local dst = Image(
	{
		IMG_Like = bg_img,
		IMG_NoData = isPreCalc,
		IMG_DeferAlloc = true,
	})

	if not isPreCalc then
		local node = DVIPComputeNode(req, "HardMixKernel", DCTL.HardMix.Kernel, "HardMixParams", DCTL.HardMix.Params)

		if node then
			local params = node:GetParamBlock(DCTL.HardMix.Params)
			params.fill = fill
			params.blend = blend
			params.curve_type = curve_type
			params.curve_blend = curve_blend
			params.blend_with_fill = blend_with_fill
			params.clamp_coverage = clamp_coverage
			params.dstsize[0] = dst.DataWindow:Width()
			params.dstsize[1] = dst.DataWindow:Height()

			node:SetParamBlock(params)
			node:AddInput("src_bg", bg_img)
			node:AddInput("src_fg", fg_img)
			node:AddOutput("dst", dst)

			if not node:RunSession(req) then
				print(dumptostring(node:GetErrorLog()))
				dst = nil
			end
		else
			dst = nil
		end
	end

	return dst
end

function Process(req)
	local bg_img = InImageBG:GetValue(req)
	local fg_img = InImageFG:GetValue(req)

	local dst = nil

	if bg_img then
		dst = render_hard_mix(req, bg_img, fg_img)
	end

	OutImage:Set(req, dst)
end

function PreCalcProcess(req)
	Process(req)
end
