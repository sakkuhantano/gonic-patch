package scanner_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.senan.xyz/gonic/db"
	"go.senan.xyz/gonic/mockfs"
	"go.senan.xyz/gonic/scanner"
	"go.senan.xyz/gonic/tags"
	"go.senan.xyz/wrtag/tags/normtag"
)

func newWatchTestScanner(t *testing.T, m *mockfs.MockFS) *scanner.Scanner {
	t.Helper()
	settings := map[*tags.Spec]tags.MultiValueSetting{
		tags.Genre:       {Mode: tags.Delim, Delim: ";"},
		tags.Artist:      {Mode: tags.Multi},
		tags.AlbumArtist: {Mode: tags.Multi},
		tags.ISRC:        {Mode: tags.Delim, Delim: ";"},
	}
	return scanner.New([]string{m.TmpDir()}, m.DB(), settings, m.TagReader(), "", true, nil)
}

func waitForTrackCount(t *testing.T, dbc *db.DB, want int) {
	t.Helper()
	deadline := time.Now().Add(25 * time.Second)
	for time.Now().Before(deadline) {
		var got int
		require.NoError(t, dbc.Model(&db.Track{}).Count(&got).Error)
		if got == want {
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
	var got int
	require.NoError(t, dbc.Model(&db.Track{}).Count(&got).Error)
	t.Fatalf("watcher did not converge to %d tracks; got %d", want, got)
}

func TestPatchedWatcherCreateDeleteRenameAndCleanup(t *testing.T) {
	m := mockfs.New(t)
	m.SetTrack("artist-a/album-a/one.flac", func(info *mockfs.TagInfo) {
		normtag.Set(info.Tags, normtag.Artist, "artist-a")
		normtag.Set(info.Tags, normtag.AlbumArtist, "artist-a")
		normtag.Set(info.Tags, normtag.Album, "album-a")
		normtag.Set(info.Tags, normtag.Title, "one")
	})

	sc := newWatchTestScanner(t, m)
	_, err := sc.ScanAndClean(scanner.ScanOptions{})
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- sc.ExecuteWatch(ctx) }()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-done:
			require.True(t, err == nil || errors.Is(err, context.Canceled))
		case <-time.After(3 * time.Second):
			t.Error("watcher did not stop after context cancellation")
		}
	})
	time.Sleep(500 * time.Millisecond)

	// A new MP3-like file should update only its containing album.
	m.SetTrack("artist-a/album-a/two.flac", func(info *mockfs.TagInfo) {
		normtag.Set(info.Tags, normtag.Artist, "artist-a")
		normtag.Set(info.Tags, normtag.AlbumArtist, "artist-a")
		normtag.Set(info.Tags, normtag.Album, "album-a")
		normtag.Set(info.Tags, normtag.Title, "two")
	})
	waitForTrackCount(t, m.DB(), 2)

	// Removing one track must remove its database row.
	require.NoError(t, os.Remove(filepath.Join(m.TmpDir(), "artist-a/album-a/two.flac")))
	waitForTrackCount(t, m.DB(), 1)

	// Renaming an album directory must preserve its track and update its path.
	require.NoError(t, os.Rename(
		filepath.Join(m.TmpDir(), "artist-a/album-a"),
		filepath.Join(m.TmpDir(), "artist-a/album-renamed"),
	))
	waitForTrackCount(t, m.DB(), 1)
	var renamed db.Album
	require.NoError(t, m.DB().Where("right_path = ?", "album-renamed").First(&renamed).Error)

	// Deleting the renamed album must remove its tracks and album records.
	require.NoError(t, os.RemoveAll(filepath.Join(m.TmpDir(), "artist-a/album-renamed")))
	waitForTrackCount(t, m.DB(), 0)
	var albums int
	require.NoError(t, m.DB().Model(&db.Album{}).Where("right_path = ?", "album-renamed").Count(&albums).Error)
	require.Zero(t, albums)
}
