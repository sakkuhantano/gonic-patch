
#!/usr/bin/env python3
"""Patch gonic v0.22.0 with shallow watcher scans and scoped DB cleanup."""

from pathlib import Path
import subprocess
import sys
import re

SOURCE = Path("scanner/scanner.go")


def fail(message):
    print(f"PATCH ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


if not SOURCE.is_file():
    fail("Run this script from the gonic source root; scanner/scanner.go not found")

src = SOURCE.read_text()
start_marker = "func (s *Scanner) ExecuteWatch(ctx context.Context) error {"
end_marker = "\nfunc watchCallback("
start = src.find(start_marker)
end = src.find(end_marker, start)

if start < 0 or end < 0:
    fail("Expected gonic v0.22.0 ExecuteWatch/watchCallback markers not found")

if "func (s *Scanner) cleanWatchTracks(" in src:
    fail("Watcher cleanup helpers already exist; refusing to patch twice")

new_code = r'''func (s *Scanner) ExecuteWatch(ctx context.Context) error {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("creating watcher: %w", err)
	}
	defer watcher.Close()

	const batchInterval = 10 * time.Second
	batchT := time.NewTimer(batchInterval)
	batchT.Stop()

	// Keep a record of watched directories so Remove/Rename events can
	// distinguish a removed directory from a removed file.
	watchedDirs := map[string]struct{}{}

	registerTree := func(root string) {
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}

			if d.IsDir() {
				cleanPath := filepath.Clean(path)

				// Do not add a directory to fsnotify more than once.
				// WalkDir must still continue into its children.
				if _, exists := watchedDirs[cleanPath]; exists {
					return nil
				}
                
                //log.Printf("WATCH ADD TRY path=%q", path)
				if err := watchCallback(watcher, path, d, nil); err != nil {
                    log.Printf("WATCH ADD FAILED path=%q err=%v", path, err)
					return err
				}

				// Mark it watched only after watchCallback succeeds.
                //log.Printf("WATCH ADD OK path=%q", path)
				watchedDirs[cleanPath] = struct{}{}
				return nil
			}

			return watchCallback(watcher, path, d, nil)
		})

		if err != nil {
			log.Printf("error registering watcher tree %q: %v", root, err)
		}
	}

	for _, dir := range s.musicDirs {
		registerTree(dir)
	}

	// batchRoots: scan only immediate child folders of these parents.
	// batchFiles: rescan only the album folder containing changed files.
	// batchRemoved: clean records for paths that disappeared or were renamed.
	batchRoots := map[string]struct{}{}
	batchFiles := map[string]struct{}{}
	batchRemoved := map[string]struct{}{}

	queueParent := func(path string, isDir bool) {
		parent := filepath.Dir(path)
		if isDir {
			batchRoots[parent] = struct{}{}
		} else {
			batchFiles[parent] = struct{}{}
		}
	}

	for {
		select {
		case <-batchT.C:
			if len(batchRoots)+len(batchFiles)+len(batchRemoved) == 0 {
				break
			}
			if !s.StartScanning() {
				batchT.Reset(batchInterval)
				break
			}

			// Delete only the database subtree corresponding to a removed
			// path. Keep cleanup limited to the affected subtree.
			for removed := range batchRemoved {
				if err := s.cleanWatchRemovedPath(removed); err != nil {
					log.Printf("watch cleanup for %q failed: %v", removed, err)
				}

				prefix := filepath.Clean(removed) + string(filepath.Separator)
				for dir := range watchedDirs {
					if dir == filepath.Clean(removed) || strings.HasPrefix(dir, prefix) {
						delete(watchedDirs, dir)
					}
				}
			}

			// Folder changes: inspect the parent, then scan each immediate
			// child directory only. Do not recursively scan child albums.
			for root := range batchRoots {
				items, readErr := os.ReadDir(root)
				if readErr != nil {
					if !errors.Is(readErr, os.ErrNotExist) {
						log.Printf("watch read %q failed: %v", root, readErr)
					}
					continue
				}

				for _, item := range items {
					if !item.IsDir() {
						continue
					}

                    child := filepath.Join(root, item.Name())
                    cleanChild := filepath.Clean(child)

                    // Refresh the watch after the directory create/rename has settled.
                    //if err := watcher.Remove(cleanChild); err != nil {
                    //    log.Printf("WATCH REMOVE old path=%q: %v", cleanChild, err)
                    //}

                    if err := watcher.Add(cleanChild); err != nil {
                        log.Printf("WATCH ADD FAILED path=%q err=%v", cleanChild, err)
                        continue
                    }

                    watchedDirs[cleanChild] = struct{}{}
                    //log.Printf("WATCH REFRESH OK path=%q", cleanChild)

                    // Explicitly verify that this immediate child is readable.
                    if _, childErr := os.ReadDir(child); childErr != nil {
                        log.Printf("watch read child %q failed: %v", child, childErr)
                        continue
                    }                    
                    
					st := &State{
						seenTracks: map[int]struct{}{},
						seenAlbums: map[int]struct{}{},
					}
					if err := s.scanCallback(st, child, item, nil); err != nil {
						log.Printf("watch scan %q failed: %v", child, err)
						continue
					}
					// scanCallback records scan errors in State and returns nil.
					// Never delete records when the scan was incomplete.
					if len(st.errs) != 0 {
						log.Printf("watch scan %q incomplete; skipping cleanup", child)
						continue
					}
					if err := s.cleanWatchTracks(child, st); err != nil {
						log.Printf("watch track cleanup %q failed: %v", child, err)
					}
				}
			}

			// File changes: scan only the containing album directory.
			for root := range batchFiles {
				musicDir, relPath := musicDirRelative(s.musicDirs, root)
				if musicDir == "" || relPath == "" || musicDir == root {
					continue
				}

				parentItems, readErr := os.ReadDir(filepath.Dir(root))
				if readErr != nil {
					log.Printf("watch parent read for %q failed: %v", root, readErr)
					continue
				}

				var entry fs.DirEntry
				for _, candidate := range parentItems {
					if candidate.Name() == filepath.Base(root) && candidate.IsDir() {
						entry = candidate
						break
					}
				}
				if entry == nil {
					continue
				}

				st := &State{
					seenTracks: map[int]struct{}{},
					seenAlbums: map[int]struct{}{},
				}
				if err := s.scanCallback(st, root, entry, nil); err != nil {
					log.Printf("watch scan %q failed: %v", root, err)
					continue
				}
				if len(st.errs) != 0 {
					log.Printf("watch scan %q incomplete; skipping cleanup", root)
					continue
				}
				if err := s.cleanWatchTracks(root, st); err != nil {
					log.Printf("watch track cleanup %q failed: %v", root, err)
				}
			}

			clear(batchRoots)
			clear(batchFiles)
			clear(batchRemoved)
			s.StopScanning()

		case event, ok := <-watcher.Events:
			if !ok {
				return nil
			}
			path := filepath.Clean(event.Name)
            //log.Printf("WATCH EVENT name=%q op=%s", path, event.Op.String())

			if event.Op&(fsnotify.Remove|fsnotify.Rename) != 0 {
				_, wasDir := watchedDirs[path]
				batchRemoved[path] = struct{}{}
				queueParent(path, wasDir)
				batchT.Reset(batchInterval)
				continue
			}

			if event.Op&(fsnotify.Create|fsnotify.Write) == 0 {
				continue
			}

			info, statErr := os.Stat(path)
			if statErr != nil {
				continue
			}
			if info.IsDir() {
				queueParent(path, true)
				registerTree(path)
			} else {
				queueParent(path, false)
			}
			batchT.Reset(batchInterval)

		case watchErr, ok := <-watcher.Errors:
			if !ok {
				return nil
			}
			log.Printf("error from watcher: %v", watchErr)

		case <-ctx.Done():
			return nil
		}
	}
}

// cleanWatchTracks removes missing tracks from exactly one album folder.
func (s *Scanner) cleanWatchTracks(root string, st *State) error {
	musicDir, relPath := musicDirRelative(s.musicDirs, root)
	if musicDir == "" || relPath == "" || musicDir == root {
		return nil
	}

	leftPath, rightPath := filepath.Split(relPath)
	var album db.Album
	err := s.db.Where(
		"root_dir=? AND left_path=? AND right_path=?",
		musicDir, leftPath, rightPath,
	).First(&album).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil
		}
		return err
	}

	var tracks []db.Track
	if err := s.db.Where("album_id=?", album.ID).Find(&tracks).Error; err != nil {
		return err
	}

	var missingIDs []int
	for _, track := range tracks {
		if _, exists := st.seenTracks[track.ID]; !exists {
			missingIDs = append(missingIDs, track.ID)
		}
	}
	if len(missingIDs) == 0 {
		return nil
	}

	return s.db.Transaction(func(tx *db.DB) error {
		if err := tx.Where(
			"entry_id_type=? AND entry_id IN (?)",
			db.BookmarkEntryTrack, missingIDs,
		).Delete(&db.Bookmark{}).Error; err != nil {
			return fmt.Errorf("delete bookmarks for missing tracks: %w", err)
		}
		if err := tx.Where("id IN (?)", missingIDs).Delete(&db.Track{}).Error; err != nil {
			return fmt.Errorf("delete missing tracks: %w", err)
		}
		return nil
	})
}

// cleanWatchRemovedPath removes albums and tracks inside one removed path.
// The path must belong to a configured music root; unrelated albums are kept.
func (s *Scanner) cleanWatchRemovedPath(removed string) error {
	removed = filepath.Clean(removed)
	musicDir, _ := musicDirRelative(s.musicDirs, removed)
	if musicDir == "" {
		return nil
	}

	// Restrict the candidate set to the configured music root. Querying every
	// album in the library for each Remove/Rename event scales poorly as the
	// library grows and needlessly touches unrelated roots.
	var albums []db.Album
	if err := s.db.Where("root_dir = ?", musicDir).Find(&albums).Error; err != nil {
		return err
	}

	removeIDs := make(map[int]struct{})
	for _, album := range albums {
		albumPath := filepath.Clean(filepath.Join(
			album.RootDir, album.LeftPath, album.RightPath,
		))

		// Both paths are filesystem paths. Rel is "." for an exact match;
		// a descendant is accepted only if it does not escape via "..".
		rel, err := filepath.Rel(removed, albumPath)
		if err != nil {
			continue
		}
		if rel != "." &&
			(rel == ".." ||
				strings.HasPrefix(rel, ".."+string(filepath.Separator)) ||
				filepath.IsAbs(rel)) {
			continue
		}

		removeIDs[album.ID] = struct{}{}
	}
	if len(removeIDs) == 0 {
		return nil
	}

	var albumIDs []int
	for id := range removeIDs {
		albumIDs = append(albumIDs, id)
	}

	return s.db.Transaction(func(tx *db.DB) error {
		var tracks []db.Track
		if err := tx.Where("album_id IN (?)", albumIDs).Find(&tracks).Error; err != nil {
			return fmt.Errorf("find tracks under removed path: %w", err)
		}

		var trackIDs []int
		for _, track := range tracks {
			trackIDs = append(trackIDs, track.ID)
		}

		if len(trackIDs) > 0 {
			if err := tx.Where(
				"entry_id_type=? AND entry_id IN (?)",
				db.BookmarkEntryTrack, trackIDs,
			).Delete(&db.Bookmark{}).Error; err != nil {
				return fmt.Errorf("delete bookmarks under removed path: %w", err)
			}
			if err := tx.Where("id IN (?)", trackIDs).Delete(&db.Track{}).Error; err != nil {
				return fmt.Errorf("delete tracks under removed path: %w", err)
			}
		}

		if err := tx.Where("id IN (?)", albumIDs).Delete(&db.Album{}).Error; err != nil {
			return fmt.Errorf("delete albums under removed path: %w", err)
		}
		return nil
	})
}

'''

src = src[:start] + new_code + src[end:]
SOURCE.write_text(src)

try:
    subprocess.run(["gofmt", "-w", str(SOURCE)], check=True)
except (OSError, subprocess.CalledProcessError) as exc:
    fail(f"gofmt failed: {exc}")

patched = SOURCE.read_text()
watch_start = patched.find(start_marker)
watch_end = patched.find("\nfunc (s *Scanner) cleanWatchTracks(", watch_start)
watch = patched[watch_start:watch_end]

required = [
    "batchRoots",
    "batchRemoved",
    "os.ReadDir(root)",
    "os.ReadDir(child)",
    "cleanWatchTracks",
    "musicDirRelative",
]
for token in required:
    if token not in watch:
        fail(f"ExecuteWatch verifier token missing: {token}")


# Remove Go line comments before checking for an actual function call.
watch_without_comments = re.sub(r"(?m)//.*$", "", watch)
if re.search(r"\bScanAndClean\s*\(", watch_without_comments):
    fail("ExecuteWatch must not call global ScanAndClean()")
if "filepath.WalkDir(child" in watch:
    fail("Rescan must not recursively walk child folders")

print("Patch applied; gofmt and static verifier checks passed.")
print("This script does not claim that a Docker build or runtime test passed.")
