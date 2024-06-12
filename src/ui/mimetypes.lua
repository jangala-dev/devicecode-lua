-- mimetypes.lua
-- Version 1.0.0

--[[
Copyright (c) 2011 Matthew "LeafStorm" Frazier

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

======

In addition, the MIME types contained in the Software were
originally obtained from the Apache HTTP Server available under the 
Apache Software License, Version 2.0 license
(http://directory.fsf.org/wiki/License:Apache2.0)
]]

-- This table is the one that actually contains the exported functions.

local mimetypes = {}

mimetypes.version = '1.0.0'


-- Extracts the extension from a filename and returns it.
-- The extension must be at the end of the string, and preceded by a dot and
-- at least one other character. Only the last part will be returned (so
-- "package-1.2.tar.gz" will return "gz").
-- If there is no extension, this function will return nil.

local function extension (filename)
    return filename:match(".+%.([%a%d]+)$")
end


-- Creates a deep copy of the given table.

local function copy (tbl)
    local ntbl = {}
    for key, value in pairs(tbl) do
        if type(value) == 'table' then
            ntbl[key] = copy(value)
        else
            ntbl[key] = value
        end
    end
    return ntbl
end


-- This is the default MIME type database.
-- It is a table with two members - "extensions" and "filenames".
-- The filenames table maps complete file names (like README) to MIME types.
-- The extensions just maps the files' extensions (like jpg) to types.

local defaultdb = {
     -- The MIME types. Remember to not include the dot on the extension.
     extensions = {
          ['log']         = 'text/plain',
          ['src']         = 'application/x-wais-source',
          ['jpeg']        = 'image/jpeg',
          ['mp4']         = 'video/mp4',
          ['xhtml']       = 'application/xhtml+xml',
          ['xml']         = 'application/xml',
          ['appcache']    = 'text/cache-manifest',
          ['rtx']         = 'text/richtext',
          ['jpg']         = 'image/jpeg',
          ['scs']         = 'application/scvp-cv-response',
          ['png']         = 'image/png',
          ['list']        = 'text/plain',
          ['jpe']         = 'image/jpeg',
          ['xsl']         = 'application/xml',
          ['in']          = 'text/plain',
          ['htm']         = 'text/html',
          ['html']        = 'text/html',
          ['webp']        = 'image/webp',
          ['svgz']        = 'image/svg+xml',
          ['svg']         = 'image/svg+xml',
          ['zip']         = 'application/zip',
          ['gif']         = 'image/gif',
          ['bin']         = 'application/octet-stream',
          ['dump']        = 'application/octet-stream',
          ['dist']        = 'application/octet-stream',
          ['distz']       = 'application/octet-stream',
          ['jsonml']      = 'application/jsonml+json',
          ['txt']         = 'text/plain',
          ['ecma']        = 'application/ecmascript',
          ['json']        = 'application/json',
          ['conf']        = 'text/plain',
          ['pkg']         = 'application/octet-stream',
          ['pdf']         = 'application/pdf',
          ['m1v']         = 'video/mpeg',
          ['js']          = 'application/javascript',
          ['m3a']         = 'audio/mpeg',

          -- aditional extensions

          ['crx']         = 'application/x-chrome-extension',
          ['htc']         = 'text/x-component',
          ['manifest']    = 'text/cache-manifest',
          ['buffer']      = 'application/octet-stream',
          ['m4p']         = 'application/mp4',
          ['m4a']         = 'audio/mp4',
          ['ts']          = 'video/MP2T',
          ['webapp']      = 'application/x-web-app-manifest+json',
          ['lua']         = 'text/x-lua',
          ['luac']        = 'application/x-lua-bytecode',
          ['markdown']    = 'text/x-markdown',
          ['md']          = 'text/x-markdown',
          ['mkd']         = 'text/x-markdown',
          ['ini']         = 'text/plain',
          ['mdp']         = 'application/dash+xml',
          ['map']         = 'application/json',
          ['xsd']         = 'application/xml',
          ['opus']        = 'audio/ogg',
          ['gz']          = 'application/x-gzip'
     },

     -- This contains filename overrides for certain files, like README files.
     -- Sort them in the same order as extensions.

     filenames = {
          ['COPYING']  = 'text/plain',
          ['LICENSE']  = 'text/plain',
          ['Makefile'] = 'text/x-makefile',
          ['README']   = 'text/plain'
     }
}


-- Creates a copy of the MIME types database for customization.

function mimetypes.copy (db)
    db = db or defaultdb
    return copy(db)
end


-- Guesses the MIME type of the file with the given name.
-- It is returned as a string. If the type cannot be guessed, then nil is
-- returned.

function mimetypes.guess (filename, db)
    db = db or defaultdb
    if db.filenames[filename] then
        return db.filenames[filename]
    end
    local ext = extension(filename)
    if ext then
        return db.extensions[ext]
    end
    return nil
end

return mimetypes