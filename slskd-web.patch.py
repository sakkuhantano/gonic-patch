from pathlib import Path
# ============================================================
# TARGET FILES
# ============================================================
SEARCH_TARGET = Path(
    "/src/src/web/src/components/Search/Detail/SearchDetail.jsx"
)
INFO_TARGET = Path(
    "/src/src/web/src/components/System/Info/index.jsx"
)
APPLICATION_TARGET = Path(
    "/src/src/web/src/lib/application.js"
)
DOWNLOAD_SERVICE_TARGET = Path(
    "/src/src/slskd/Transfers/Downloads/DownloadService.cs"
)
# ============================================================
# 1. SEARCH DETAIL - FORMAT FILTER
# ============================================================
search_source = SEARCH_TARGET.read_text()
# ------------------------------------------------------------
# 1A. Add format options + filtering helper
# ------------------------------------------------------------
if "const formatOptions = [" not in search_source:
    marker = "const SearchDetail = ({"
    if marker not in search_source:
        raise RuntimeError(
            "Could not find SearchDetail component marker"
        )
    format_helpers = """const formatOptions = [
      { key: 'flac', text: 'FLAC', value: '.flac' },
      { key: 'mp3', text: 'MP3', value: '.mp3' },
      { key: 'm4a', text: 'M4A', value: '.m4a' },
      { key: 'aac', text: 'AAC', value: '.aac' },
      { key: 'ogg', text: 'OGG', value: '.ogg' },
      { key: 'opus', text: 'OPUS', value: '.opus' },
      { key: 'wav', text: 'WAV', value: '.wav' },
      { key: 'ape', text: 'APE', value: '.ape' },
      { key: 'aiff', text: 'AIFF', value: '.aiff' },
      { key: 'wma', text: 'WMA', value: '.wma' },
      { key: 'wv', text: 'WV', value: '.wv' },
    ];

    const allFormats = formatOptions.map((format) => format.value);

    const filterResponseByFormats = (response, formats) => {
      if (formats.length === formatOptions.length) {
        return response;
      }
      const allowedExtensions = formats.map((format) => format.toLowerCase());
      const filterFiles = (fileList = []) =>
        fileList.filter((file) => {
          const filename = (file.filename || '').toLowerCase();
          return allowedExtensions.some((extension) =>
            filename.endsWith(extension),
          );
        });
      const files = filterFiles(response.files);
      const lockedFiles = filterFiles(response.lockedFiles);
      return {
        ...response,
        files,
        lockedFiles,
        fileCount: files.length,
        lockedFileCount: lockedFiles.length,
      };
    };
    """
    search_source = search_source.replace(
        marker,
        format_helpers + marker,
        1,
    )
    print("[slskd-patch] Added format filter helpers")
else:
    print("[slskd-patch] Format filter helpers already present")
# ------------------------------------------------------------
# 1B. Add selectedFormats state
# ------------------------------------------------------------
state_marker = (
    "const [selectedFormats, setSelectedFormats] = "
    "useState(allFormats);"
)
if state_marker not in search_source:
    old = """  const [resultFilters, setResultFilters] = useState('');
"""
    new = """  const [resultFilters, setResultFilters] = useState('');
  const [selectedFormats, setSelectedFormats] = useState(allFormats);
"""
    if old not in search_source:
        raise RuntimeError(
            "Could not find resultFilters state"
        )
    search_source = search_source.replace(old, new, 1)
    print("[slskd-patch] Added selectedFormats state")
else:
    print("[slskd-patch] selectedFormats state already present")
# ------------------------------------------------------------
# 1C. Apply format filtering to results
# ------------------------------------------------------------
format_map = (
    ".map((response) => filterResponseByFormats(response, selectedFormats))"
)
if format_map not in search_source:
    old = """       .map((response) => filterResponse({ filters, response }))
"""
    # Be tolerant of indentation differences.
    if old not in search_source:
        old = """      .map((response) => filterResponse({ filters, response }))
"""
    new = (
        old
        + "      .map((response) => filterResponseByFormats(response, selectedFormats))\n"
    )
    if old not in search_source:
        raise RuntimeError(
            "Could not find filterResponse() mapping"
        )
    search_source = search_source.replace(old, new, 1)
    print("[slskd-patch] Added format filtering to search results")
else:
    print("[slskd-patch] Format filtering already applied")
# ------------------------------------------------------------
# 1D. Add selectedFormats to useMemo dependency array
# ------------------------------------------------------------
if "    selectedFormats,\n" not in search_source:
    old = """    resultSort,
    results,
  ]);
"""
    new = """    resultSort,
    results,
    selectedFormats,
  ]);
"""
    if old not in search_source:
        raise RuntimeError(
            "Could not find SearchDetail useMemo dependency array"
        )
    search_source = search_source.replace(old, new, 1)
    print("[slskd-patch] Added selectedFormats to useMemo dependencies")
else:
    print("[slskd-patch] selectedFormats already present in dependencies")
# ------------------------------------------------------------
# 1E. Reset format selection when SearchDetail resets
# ------------------------------------------------------------
reset_marker = """  const reset = () => {
"""
if "setSelectedFormats(allFormats);" not in search_source:
    if reset_marker not in search_source:
        raise RuntimeError(
            "Could not find SearchDetail reset() function"
        )
    old = """  const reset = () => {
    setLoading(false);
"""
    new = """  const reset = () => {
    setSelectedFormats(allFormats);
    setLoading(false);
"""
    if old not in search_source:
        raise RuntimeError(
            "Could not find expected reset() body"
        )
    search_source = search_source.replace(old, new, 1)
    print("[slskd-patch] Added format reset handling")
else:
    print("[slskd-patch] Format reset handling already present")
# ------------------------------------------------------------
# 1F. Add Format dropdown
# ------------------------------------------------------------
if 'className="search-options-format"' not in search_source:
    # The stock 0.26.0 source has the sort dropdown directly
    # inside the search-options Segment.
    marker = """            <Dropdown
              button
              className="search-options-sort icon"
"""
    if marker not in search_source:
        raise RuntimeError(
            "Could not find SearchDetail sort dropdown"
        )
    format_dropdown = """            <Dropdown
              className="search-options-format"
              clearable
              fluid
              labeled
              multiple
              onChange={(_event, { value }) =>
                setSelectedFormats(value?.length ? value : allFormats)
              }
              options={formatOptions}
              placeholder="Format"
              search
              selection
              text={
                selectedFormats.length === formatOptions.length
                  ? 'All formats'
                  : undefined
              }
              value={selectedFormats}
            />
"""
    search_source = search_source.replace(
        marker,
        format_dropdown + marker,
        1,
    )
    print("[slskd-patch] Added Format dropdown")
else:
    print("[slskd-patch] Format dropdown already present")
SEARCH_TARGET.write_text(search_source)
# ============================================================
# 2. SYSTEM INFO - REMOVE SHUTDOWN / RESTART UI
# ============================================================
info_source = INFO_TARGET.read_text()
# ------------------------------------------------------------
# 2A. Remove restart/shutdown imports
# ------------------------------------------------------------
old = """import { getVersion, restart, shutdown } from '../../../lib/application';
"""
new = """import { getVersion } from '../../../lib/application';
"""
if old in info_source:
    info_source = info_source.replace(old, new, 1)
    print("[slskd-patch] Removed restart/shutdown imports")
elif "import { getVersion } from '../../../lib/application';" in info_source:
    print("[slskd-patch] restart/shutdown imports already removed")
else:
    raise RuntimeError(
        "Could not find expected application import"
    )
# ------------------------------------------------------------
# 2B. Remove pendingRestart local state
# ------------------------------------------------------------
pending_restart_line = """  const { pendingRestart } = state;
"""

if pending_restart_line in info_source:
    info_source = info_source.replace(
        pending_restart_line,
        "",
        1,
    )
    print("[slskd-patch] Removed pendingRestart local state")
else:
    print("[slskd-patch] pendingRestart local state already removed")
# ------------------------------------------------------------
# 2C. Remove Shutdown modal
# ------------------------------------------------------------
shutdown_block = """        <Modal
          actions={[
            'Cancel',
            {
              content: 'Shut Down',
              key: 'done',
              negative: true,
              onClick: shutdown,
            },
          ]}
          centered
          content="Are you sure you want to shut the application down?  You'll need to manually start it again."
          header={
            <Header
              content="Confirm Shutdown"
              icon="redo"
            />
          }
          size="mini"
          trigger={
            <ShrinkableButton
              disabled={!contents}
              icon="shutdown"
              mediaQuery="(max-width: 686px)"
              negative
            >
              Shut Down
            </ShrinkableButton>
          }
        />
"""
if shutdown_block in info_source:
    info_source = info_source.replace(
        shutdown_block,
        "",
        1,
    )
    print("[slskd-patch] Removed Shutdown button/modal")
elif "onClick={shutdown}" not in info_source:
    print("[slskd-patch] Shutdown button/modal already removed")
else:
    raise RuntimeError(
        "Could not safely remove Shutdown modal"
    )
# ------------------------------------------------------------
# 2D. Remove Restart modal
# ------------------------------------------------------------
restart_block = """        <Modal
          actions={[
            'Cancel',
            {
              content: 'Restart',
              key: 'done',
              negative: true,
              onClick: restart,
            },
          ]}
          centered
          content="Are you sure you want restart the application?"
          header={
            <Header
              content="Confirm Restart"
              icon="redo"
            />
          }
          size="mini"
          trigger={
            <ShrinkableButton
              color={pendingRestart ? 'yellow' : undefined}
              disabled={!contents}
              icon="redo"
              mediaQuery="(max-width: 686px)"
              negative={!pendingRestart}
            >
              Restart
            </ShrinkableButton>
          }
        />
"""
if restart_block in info_source:
    info_source = info_source.replace(
        restart_block,
        "",
        1,
    )
    print("[slskd-patch] Removed Restart button/modal")
elif "onClick={restart}" not in info_source:
    print("[slskd-patch] Restart button/modal already removed")
else:
    raise RuntimeError(
        "Could not safely remove Restart modal"
    )
# ------------------------------------------------------------
# 2E. Remove unused Header / Modal imports
# ------------------------------------------------------------
old = """import { Divider, Header, Modal } from 'semantic-ui-react';
"""
new = """import { Divider } from 'semantic-ui-react';
"""
if old in info_source:
    info_source = info_source.replace(old, new, 1)
    print("[slskd-patch] Removed unused Header/Modal imports")
elif "import { Divider } from 'semantic-ui-react';" in info_source:
    print("[slskd-patch] Header/Modal imports already removed")
else:
    raise RuntimeError(
        "Could not find expected semantic-ui-react import"
    )
info_source = info_source.replace(
    "  }, [state]);\n\n\n  return (",
    "  }, [state]);\n\n  return (",
    1,
)

INFO_TARGET.write_text(info_source)
# ============================================================
# 3. APPLICATION.JS - REMOVE FRONTEND LIFECYCLE API EXPORTS
# ============================================================
application_source = APPLICATION_TARGET.read_text()
# ------------------------------------------------------------
# 3A. Remove restart()
# ------------------------------------------------------------
restart_api = """export const restart = async () => {
  return api.put('/application');
};
"""
if restart_api in application_source:
    application_source = application_source.replace(
        restart_api,
        "",
        1,
    )
    print("[slskd-patch] Removed frontend restart() API")
elif "export const restart = async" not in application_source:
    print("[slskd-patch] frontend restart() API already removed")
else:
    raise RuntimeError(
        "Could not safely remove restart() API"
    )
# ------------------------------------------------------------
# 3B. Remove shutdown()
# ------------------------------------------------------------
shutdown_api = """export const shutdown = async () => {
  return api.delete('/application');
};
"""
if shutdown_api in application_source:
    application_source = application_source.replace(
        shutdown_api,
        "",
        1,
    )
    print("[slskd-patch] Removed frontend shutdown() API")
elif "export const shutdown = async" not in application_source:
    print("[slskd-patch] frontend shutdown() API already removed")
else:
    raise RuntimeError(
        "Could not safely remove shutdown() API"
    )

APPLICATION_TARGET.write_text(application_source)
# ============================================================
# 4. DOWNLOAD SERVICE - CLEANUP EMPTY INCOMPLETE DIRECTORIES
# ============================================================
download_source = DOWNLOAD_SERVICE_TARGET.read_text()

# ------------------------------------------------------------
# 4A. Add recursive cleanup helper
# ------------------------------------------------------------
cleanup_helper_marker = """        private void CleanupEmptyIncompleteDirectories(
"""

if cleanup_helper_marker not in download_source:
    class_marker = """        private ILogger Log { get; } = Serilog.Log.ForContext<DownloadService>();
"""

    if class_marker not in download_source:
        raise RuntimeError(
            "Could not find DownloadService logger property"
        )

    cleanup_helper = """        private void CleanupEmptyIncompleteDirectories(
            string sourceFilename,
            string incompleteDirectory)
        {
            var incompleteRoot = Path.GetFullPath(incompleteDirectory)
                .TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar);

            var currentDirectory = Path.GetDirectoryName(
                Path.GetFullPath(sourceFilename));

            while (!string.IsNullOrEmpty(currentDirectory))
            {
                var currentFullPath = Path.GetFullPath(currentDirectory);

                // Never delete the configured incomplete root itself.
                if (string.Equals(
                    currentFullPath,
                    incompleteRoot,
                    StringComparison.Ordinal))
                {
                    break;
                }

                // Safety guard: only clean directories below incomplete root.
                if (!currentFullPath.StartsWith(
                    incompleteRoot + Path.DirectorySeparatorChar,
                    StringComparison.Ordinal))
                {
                    break;
                }

                try
                {
                    if (!Directory.Exists(currentFullPath))
                    {
                        currentDirectory = Path.GetDirectoryName(currentFullPath);
                        continue;
                    }

                    // Stop as soon as this directory contains anything.
                    if (Directory.EnumerateFileSystemEntries(currentFullPath).Any())
                    {
                        break;
                    }

                    Directory.Delete(currentFullPath);

                    Log.Debug(
                        "Removed empty incomplete directory {Directory}",
                        currentFullPath);

                    currentDirectory = Path.GetDirectoryName(currentFullPath);
                }
                catch (Exception ex) when (
                    ex is IOException ||
                    ex is UnauthorizedAccessException)
                {
                    // Another download may have created something here,
                    // or the directory may already have been removed.
                    // Never make a successful download fail because cleanup
                    // could not remove an empty directory.
                    Log.Debug(
                        ex,
                        "Could not remove empty incomplete directory {Directory}",
                        currentFullPath);

                    break;
                }
            }
        }

"""

    download_source = download_source.replace(
        class_marker,
        class_marker + cleanup_helper,
        1,
    )

    print(
        "[slskd-patch] Added recursive incomplete-directory cleanup helper"
    )
else:
    print(
        "[slskd-patch] Recursive incomplete-directory cleanup helper already present"
    )

# ------------------------------------------------------------
# 4B. Call recursive cleanup after MoveFile()
# ------------------------------------------------------------
cleanup_call = """                 CleanupEmptyIncompleteDirectories(
                     incompleteFilename,
                     incompleteDirectory);
"""

if cleanup_call not in download_source:
    log_marker = 'Log.Information("Moved file {Filename} from {Username} from {Incomplete} to {Destination}"'

    log_index = download_source.find(log_marker)

    if log_index == -1:
        raise RuntimeError(
            "Could not find DownloadService completion log"
        )

    line_end = download_source.find("\n", log_index)

    if line_end == -1:
        raise RuntimeError(
            "Could not determine DownloadService completion log boundary"
        )

    download_source = (
        download_source[:line_end + 1]
        + cleanup_call
        + download_source[line_end + 1:]
    )

    print(
        "[slskd-patch] Added recursive incomplete-directory cleanup call"
    )
else:
    print(
        "[slskd-patch] Recursive incomplete-directory cleanup call already present"
    )
DOWNLOAD_SERVICE_TARGET.write_text(download_source)
# ============================================================
# 4. FINAL SAFETY CHECKS
# ============================================================
final_search = SEARCH_TARGET.read_text()
final_info = INFO_TARGET.read_text()
final_application = APPLICATION_TARGET.read_text()
final_download = DOWNLOAD_SERVICE_TARGET.read_text()
# ------------------------------------------------------------
# Search format filter
# ------------------------------------------------------------
required_search_markers = [
    "const formatOptions = [",
    "const allFormats = formatOptions.map",
    "const filterResponseByFormats =",
    "const [selectedFormats, setSelectedFormats] = useState(allFormats);",
    "filterResponseByFormats(response, selectedFormats)",
    'className="search-options-format"',
    "setSelectedFormats(allFormats);",
]
for marker in required_search_markers:
    if marker not in final_search:
        raise RuntimeError(
            "SAFETY CHECK FAILED: missing SearchDetail marker: "
            + marker
        )
# ------------------------------------------------------------
# Verify useMemo dependency
# ------------------------------------------------------------
filter_pos = final_search.find(
    "filterResponseByFormats(response, selectedFormats)"
)
if filter_pos == -1:
    raise RuntimeError(
        "SAFETY CHECK FAILED: format filter call missing"
    )
dependency_end = final_search.find(
    "]);",
    filter_pos,
)
if dependency_end == -1:
    raise RuntimeError(
        "SAFETY CHECK FAILED: useMemo dependency array missing"
    )
dependency_start = final_search.rfind(
    "[",
    filter_pos,
    dependency_end,
)
if dependency_start == -1:
    raise RuntimeError(
        "SAFETY CHECK FAILED: useMemo dependency array invalid"
    )
dependency_text = final_search[
    dependency_start:dependency_end
]
if "selectedFormats" not in dependency_text:
    raise RuntimeError(
        "SAFETY CHECK FAILED: selectedFormats missing "
        "from useMemo dependencies"
    )
# ------------------------------------------------------------
# Verify lifecycle UI is gone
# ------------------------------------------------------------
if "onClick={shutdown}" in final_info:
    raise RuntimeError(
        "SAFETY CHECK FAILED: Shutdown button still exists"
    )
if "onClick={restart}" in final_info:
    raise RuntimeError(
        "SAFETY CHECK FAILED: Restart button still exists"
    )
if ">Shut Down<" in final_info:
    raise RuntimeError(
        "SAFETY CHECK FAILED: Shutdown text still exists"
    )
if ">Restart<" in final_info:
    raise RuntimeError(
        "SAFETY CHECK FAILED: Restart text still exists"
    )
# ------------------------------------------------------------
# Verify imports
# ------------------------------------------------------------
if "getVersion, restart, shutdown" in final_info:
    raise RuntimeError(
        "SAFETY CHECK FAILED: restart/shutdown import remains"
    )
if "Divider, Header, Modal" in final_info:
    raise RuntimeError(
        "SAFETY CHECK FAILED: Header/Modal import remains"
    )
# ------------------------------------------------------------
# Verify frontend lifecycle exports are gone
# ------------------------------------------------------------
if "export const restart = async" in final_application:
    raise RuntimeError(
        "SAFETY CHECK FAILED: restart() export remains"
    )
if "export const shutdown = async" in final_application:
    raise RuntimeError(
        "SAFETY CHECK FAILED: shutdown() export remains"
    )
# ------------------------------------------------------------
# Verify recursive incomplete-directory cleanup
# ------------------------------------------------------------
if "private void CleanupEmptyIncompleteDirectories(" not in final_download:
    raise RuntimeError(
        "SAFETY CHECK FAILED: recursive cleanup helper missing"
    )

if "CleanupEmptyIncompleteDirectories(" not in final_download:
    raise RuntimeError(
        "SAFETY CHECK FAILED: recursive cleanup call missing"
    )

if "Never delete the configured incomplete root itself." not in final_download:
    raise RuntimeError(
        "SAFETY CHECK FAILED: incomplete root protection missing"
    )    
    
# ------------------------------------------------------------
# IMPORTANT:
#
# Do NOT check pendingRestart globally.
#
# App.jsx / System/System.jsx legitimately use pendingRestart.
# Those files are intentionally untouched.
# ------------------------------------------------------------
print("")
print("[slskd-patch] =========================================")
print("[slskd-patch] slskd Web UI patch completed successfully")
print("[slskd-patch] - Format filter: enabled")
print("[slskd-patch] - Format reset: enabled")
print("[slskd-patch] - Shutdown button: removed")
print("[slskd-patch] - Restart button: removed")
print("[slskd-patch] - Frontend lifecycle APIs: removed")
print("[slskd-patch] - App/System lifecycle state: untouched")
print("[slskd-patch] - Recursive incomplete cleanup: enabled")
print("[slskd-patch] =========================================")