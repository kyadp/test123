--!native
--!optimize 2
-- Base64 Turbocharged (Luau / Roblox)
-- Fully backward compatible with original structure but heavily optimized internally.

local Base64 = {}

local ALPHABET_STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ALPHABET_URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local PAD_BYTE = string.byte("=")
local PLUS_BYTE = string.byte("+")
local SLASH_BYTE = string.byte("/")
local DASH_BYTE = string.byte("-")
local UNDERSCORE_BYTE = string.byte("_")

-- lookup buffers same shape as original code
local lookupValueToCharacter = buffer.create(64)
local lookupCharacterToValue = buffer.create(256)

-- fill with standard alphabet mapping (0..63 -> ascii byte)
do
	for i = 1, 64 do
		local v = i - 1
		local b = string.byte(ALPHABET_STD, i)
		buffer.writeu8(lookupValueToCharacter, v, b)
		buffer.writeu8(lookupCharacterToValue, b, v)
	end
end

-- LOCALIZED references for speed
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local lenbuf = buffer.len
local createbuf = buffer.create
local bit_lshift = bit32.lshift
local bit_rshift = bit32.rshift
local bit_band = bit32.band
local bit_bor = bit32.bor

-- small helper to copy range of bytes from one buffer to another
local function copy_buffer(src, srcStart, dst, dstStart, count)
	-- indices 0-based
	for i = 0, count - 1 do
		writeu8(dst, dstStart + i, readu8(src, srcStart + i))
	end
end

-- Encode: keeps original function signature and logic but optimized
function Base64.encode(input: buffer, options: { urlSafe: boolean?, noPadding: boolean? }?)
	local inLen = lenbuf(input)
	if inLen == 0 then return createbuf(0) end

	local urlSafe = options and options.urlSafe
	local noPadding = options and options.noPadding

	-- precompute output length (with padding)
	local chunks = (inLen + 2) // 3 -- ceil(inLen/3)
	local outLen = chunks * 4
	local out = createbuf(outLen)

	-- fast locals
	local v2c = lookupValueToCharacter
	local i, o = 0, 0

	-- process full 3-byte blocks
	local limit = (inLen // 3) * 3
	while i < limit do
		-- read three bytes, combine to 24 bits
		local b1 = readu8(input, i)
		local b2 = readu8(input, i + 1)
		local b3 = readu8(input, i + 2)
		local n = bit_bor(bit_lshift(b1, 16), bit_lshift(b2, 8), b3)

		writeu8(out, o + 0, readu8(v2c, bit_rshift(n, 18)))
		writeu8(out, o + 1, readu8(v2c, bit_band(bit_rshift(n, 12), 63)))
		writeu8(out, o + 2, readu8(v2c, bit_band(bit_rshift(n, 6), 63)))
		writeu8(out, o + 3, readu8(v2c, bit_band(n, 63)))

		i += 3
		o += 4
	end

	-- remainder handling (0,1,2 bytes left)
	local rem = inLen - limit
	if rem == 1 then
		local b1 = readu8(input, limit)
		local n = bit_lshift(b1, 16)
		local a = bit_rshift(n, 18)
		local b = bit_band(bit_rshift(n, 12), 63)

		writeu8(out, o + 0, readu8(v2c, a))
		writeu8(out, o + 1, readu8(v2c, b))
		writeu8(out, o + 2, PAD_BYTE)
		writeu8(out, o + 3, PAD_BYTE)
	elseif rem == 2 then
		local b1 = readu8(input, limit)
		local b2 = readu8(input, limit + 1)
		local n = bit_bor(bit_lshift(b1, 16), bit_lshift(b2, 8))
		local a = bit_rshift(n, 18)
		local b = bit_band(bit_rshift(n, 12), 63)
		local c = bit_band(bit_rshift(n, 6), 63)

		writeu8(out, o + 0, readu8(v2c, a))
		writeu8(out, o + 1, readu8(v2c, b))
		writeu8(out, o + 2, readu8(v2c, c))
		writeu8(out, o + 3, PAD_BYTE)
	end

	-- URL-safe transform (in-place) if requested
	if urlSafe then
		for idx = 0, outLen - 1 do
			local ch = readu8(out, idx)
			if ch == PLUS_BYTE then writeu8(out, idx, DASH_BYTE)
			elseif ch == SLASH_BYTE then writeu8(out, idx, UNDERSCORE_BYTE) end
		end
	end

	-- Remove padding if noPadding requested: create trimmed buffer
	if noPadding then
		local trimmed = outLen
		while trimmed > 0 and readu8(out, trimmed - 1) == PAD_BYTE do
			trimmed -= 1
		end
		if trimmed == outLen then return out end
		local out2 = createbuf(trimmed)
		copy_buffer(out, 0, out2, 0, trimmed)
		return out2
	end

	return out
end

-- Decode: robust, supports whitespace, URL-safe, missing padding, and optional strict mode
function Base64.decode(input: buffer, options: { strict: boolean?, autoDetect: boolean? }?)
	local inLen = lenbuf(input)
	if inLen == 0 then return createbuf(0) end

	local strict = options and options.strict
	local autoDetect = options and options.autoDetect

	-- quick scan to determine if URL-safe characters exist (without tostring)
	local maybeURL = false
	for i = 0, inLen - 1 do
		local c = readu8(input, i)
		if c == DASH_BYTE or c == UNDERSCORE_BYTE then
			maybeURL = true
			break
		end
	end

	-- local table ref
	local c2v = lookupCharacterToValue

	-- We will collect 4 valid base64 character bytes at a time (skip whitespace/newline)
	local collected = {} -- small array of bytes (max 4)
	local collectedN = 0
	-- compute effective number of base64 chars (ignoring whitespace)
	local validChars = 0
	for i = 0, inLen - 1 do
		local b = readu8(input, i)
		-- treat CR/LF/space/tab as ignorable
		if b ~= 10 and b ~= 13 and b ~= 32 and b ~= 9 then
			validChars += 1
		end
	end

	-- If validChars is 0 -> empty result
	if validChars == 0 then return createbuf(0) end

	-- If missing padding, we can infer padding count: padCount = (4 - validChars % 4) % 4
	local padCount = (4 - (validChars % 4)) % 4
	local outLen = math.floor((validChars * 3) / 4) - padCount
	if outLen < 0 then outLen = 0 end
	local out = createbuf(outLen)

	local i, o = 0, 0
	local readIndex = 0
	while readIndex < inLen do
		local ch = readu8(input, readIndex)
		readIndex += 1

		-- skip whitespace-like
		if ch == 10 or ch == 13 or ch == 32 or ch == 9 then
			continue
		end

		-- normalize URL-safe to standard
		if ch == DASH_BYTE then ch = PLUS_BYTE
		elseif ch == UNDERSCORE_BYTE then ch = SLASH_BYTE end

		-- handle padding explicitly (treat '=' as value 0 but track)
		if ch == PAD_BYTE then
			collectedN += 1
			collected[collectedN] = ch
		else
			local val = readu8(c2v, ch)
			-- If char->value is 0 but actual char might be 'A' (value 0), we need to verify by re-reading the alphabet mapping:
			-- In our lookup table unfilled entries will be 0; to detect invalid character we check whether the original char actually maps or if it's zero but char ~= 'A'
			-- We detect invalid by checking if (char ~= 'A') and (val == 0) and (ch ~= string.byte("A"))
			if val == 0 and ch ~= string.byte("A") then
				-- invalid char
				if strict then
					error("Base64.decode: invalid character in input: "..tostring(ch))
				else
					-- skip invalid char (lenient)
					continue
				end
			end

			collectedN += 1
			collected[collectedN] = ch
		end

		-- when we have 4 collected bytes, decode them
		if collectedN == 4 then
			-- map bytes to values (handle '=' as 0)
			local b1 = collected[1]
			local b2 = collected[2]
			local b3 = collected[3]
			local b4 = collected[4]

			local v1 = (b1 == PAD_BYTE) and 0 or readu8(c2v, b1)
			local v2 = (b2 == PAD_BYTE) and 0 or readu8(c2v, b2)
			local v3 = (b3 == PAD_BYTE) and 0 or readu8(c2v, b3)
			local v4 = (b4 == PAD_BYTE) and 0 or readu8(c2v, b4)

			local n = bit_bor(bit_lshift(v1, 18), bit_lshift(v2, 12), bit_lshift(v3, 6), v4)

			-- write up to 3 bytes respecting outLen
			if o < outLen then writeu8(out, o, bit_rshift(n, 16)) end
			if o + 1 < outLen then writeu8(out, o + 1, bit_band(bit_rshift(n, 8), 0xFF)) end
			if o + 2 < outLen then writeu8(out, o + 2, bit_band(n, 0xFF)) end

			o += 3
			collectedN = 0
		end
	end

	-- done
	return out
end

return Base64
