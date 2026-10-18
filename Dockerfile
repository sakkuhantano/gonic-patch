# ============================================================
# SLSKD SOURCE / WEB UI BUILD STAGE
# ============================================================
FROM node:22-alpine AS slskd-web

ARG SLSKD_VERSION=0.26.0

WORKDIR /src

RUN apk add --no-cache \
    git \
    python3

RUN git clone --depth 1 --branch ${SLSKD_VERSION} \
    https://github.com/slskd/slskd.git .

# ------------------------------------------------------------
# WEB UI DEPENDENCIES
# ------------------------------------------------------------
WORKDIR /src/src/web

RUN npm ci --no-audit --no-fund

# ------------------------------------------------------------
# PATCH SLSKD SOURCE
# ------------------------------------------------------------
WORKDIR /src

COPY slskd-web.patch.py /tmp/slskd-web.patch.py

RUN python3 /tmp/slskd-web.patch.py

# ------------------------------------------------------------
# WEB UI LINT
# ------------------------------------------------------------
WORKDIR /src/src/web

RUN npx eslint --fix \
    src/components/Search/Detail/SearchDetail.jsx \
    src/components/System/Info/index.jsx \
    src/lib/application.js

# ------------------------------------------------------------
# WEB UI BUILD
# ------------------------------------------------------------
RUN npm run build


# ============================================================
# SLSKD BACKEND BUILD STAGE - .NET 10
# ============================================================
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS slskd-backend

WORKDIR /src

# Copy the already patched slskd source tree
COPY --from=slskd-web \
    /src/ \
    /src/

# ------------------------------------------------------------
# BACKEND BUILD
# ------------------------------------------------------------
RUN dotnet publish \
    src/slskd/slskd.csproj \
    -c Release \
    -r linux-x64 \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:DebugType=None \
    -p:DebugSymbols=false \
    -o /out/slskd

# ============================================================
# GONIC PATCH BUILDER
# ============================================================
FROM golang:1.26-bookworm AS gonic-builder

WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ============================================================
# Get gonic v0.22.0
# ============================================================

RUN git clone --branch v0.22.0 --depth 1 \
    https://github.com/sentriz/gonic.git .

# ============================================================
# Cache Go dependencies/build cache
# ============================================================

RUN --mount=type=cache,id=gonic-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=gonic-go-build,target=/root/.cache/go-build \
    go mod download

# ============================================================
# Patch scanner
#
# Behavior:
#
# CREATE / WRITE
#   -> scan only affected folder
#
# REMOVE file
#   -> rescan affected parent folder
#   -> remove only stale tracks from albums scanned there
#
# RENAME file
#   -> remember old path as removed
#   -> rescan affected parent folder
#   -> remove only stale track
#
# REMOVE / RENAME directory
#   -> rescan surviving parent directory
#   -> remove only the database album represented by the
#      directory that actually disappeared
#
# NEVER call ScanAndClean() from filesystem watcher.
#
# Full/manual scans continue to use the original gonic
# ScanAndClean() implementation.
#
# @eaDir and .@__thumb are excluded automatically.
# ============================================================

RUN python3 - <<'PY'
from pathlib import Path

p = Path("scanner/scanner.go")
s = p.read_text()

# ============================================================
# 1. Default exclusions
# ============================================================

old = r'''func New(musicDirs []string, db *db.DB, multiValueSettings map[*tags.Spec]tags.MultiValueSetting, tagReader tags.Reader, excludePattern string, scanEmbeddedCover bool, genreTree map[string][]string) *Scanner {
	var excludePatternRegExp *regexp.Regexp
	if excludePattern != "" {
		excludePatternRegExp = regexp.MustCompile(excludePattern)
	}'''

new = r'''func New(musicDirs []string, db *db.DB, multiValueSettings map[*tags.Spec]tags.MultiValueSetting, tagReader tags.Reader, excludePattern string, scanEmbeddedCover bool, genreTree map[string][]string) *Scanner {
	var excludePatternRegExp *regexp.Regexp

	if excludePattern == "" {
		excludePattern = `(^|[/\\])(?:@eaDir|\.@__thumb)([/\\]|$)`
	}

	if excludePattern != "" {
		excludePatternRegExp = regexp.MustCompile(excludePattern)
	}'''

if old not in s:
    raise SystemExit("PATCH ERROR: Scanner.New block not found")

s = s.replace(old, new, 1)

# ============================================================
# 2. Replace ExecuteWatch()
# ============================================================

start = s.find("func (s *Scanner) ExecuteWatch(ctx context.Context) error {")
end = s.find("\nfunc watchCallback(", start)

if start < 0 or end < 0:
    raise SystemExit("PATCH ERROR: ExecuteWatch boundaries not found")

new_execute_watch = r'''func (s *Scanner) ExecuteWatch(ctx context.Context) error {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("creating watcher: %w", err)
	}
	defer watcher.Close()

	const batchInterval = 10 * time.Second

	batchT := time.NewTimer(batchInterval)
	batchT.Stop()

	for _, dir := range s.musicDirs {
		err := filepath.WalkDir(dir, func(absPath string, d fs.DirEntry, err error) error {
			return watchCallback(watcher, absPath, d, err)
		})
		if err != nil {
			log.Printf("error watching directory tree: %v\n", err)
			continue
		}
	}

	/*
	 * batchSeen contains directories that still exist and must
	 * be rescanned.
	 *
	 * batchRemoved contains paths that disappeared. They are
	 * handled separately because a removed FILE must never cause
	 * its whole album to disappear.
	 */
	batchSeen := map[string]struct{}{}
	batchRemoved := map[string]struct{}{}

	for {
		select {
		case <-batchT.C:
			if len(batchSeen) == 0 && len(batchRemoved) == 0 {
				continue
			}

			if !s.StartScanning() {
				batchT.Reset(batchInterval)
				continue
			}

			/*
			 * ----------------------------------------------------
			 * First: rescan directories that still exist.
			 *
			 * This is deliberately done BEFORE cleanup.
			 * Therefore a renamed/new file is visible to scanCallback
			 * before stale database tracks are removed.
			 * ----------------------------------------------------
			 */
			for absPath := range batchSeen {
				if _, err := os.Stat(absPath); err != nil {
					continue
				}

				st := &State{
					seenTracks: map[int]struct{}{},
					seenAlbums: map[int]struct{}{},
				}

				/*
				 * Add newly-created directories to fsnotify.
				 */
				if err := filepath.WalkDir(absPath, func(path string, d fs.DirEntry, err error) error {
					return watchCallback(watcher, path, d, err)
				}); err != nil {
					log.Printf("error watching directory tree %q: %v\n", absPath, err)
					continue
				}

				/*
				 * Scan only this affected directory.
				 *
				 * No ScanAndClean().
				 */
				if err := filepath.WalkDir(absPath, func(path string, d fs.DirEntry, err error) error {
					return s.scanCallback(st, path, d, err)
				}); err != nil {
					log.Printf("error walking %q: %v\n", absPath, err)
					continue
				}

				/*
				 * Cleanup is scoped to albums encountered during
				 * this folder scan.
				 *
				 * This removes stale files without touching albums
				 * elsewhere in the library.
				 */
				if err := s.cleanWatchTracks(st); err != nil {
					log.Printf("error cleaning watched tracks %q: %v\n", absPath, err)
				}
			}

			/*
			 * ----------------------------------------------------
			 * Second: handle paths that disappeared completely.
			 *
			 * Only a directory that actually disappeared can cause
			 * an album deletion.
			 *
			 * A missing audio FILE is NOT allowed to delete the
			 * album here; its parent directory was already rescanned
			 * above and cleanWatchTracks() handles that case.
			 * ----------------------------------------------------
			 */
			for absPath := range batchRemoved {
				if _, err := os.Stat(absPath); err == nil {
					/*
					 * The path exists again, so this was most likely
					 * part of a rename/create sequence. The surviving
					 * parent scan handles it.
					 */
					continue
				}

				if err := s.cleanWatchRemovedPath(absPath); err != nil {
					log.Printf("error cleaning removed path %q: %v\n", absPath, err)
				}
			}

			s.StopScanning()

			clear(batchSeen)
			clear(batchRemoved)

		case event := <-watcher.Events:
			/*
			 * ----------------------------------------------------
			 * REMOVE / RENAME
			 * ----------------------------------------------------
			 */
			if event.Op&(fsnotify.Remove|fsnotify.Rename) != 0 {
				eventPath := event.Name
				parent := filepath.Dir(eventPath)

				/*
				 * Remember the exact old path.
				 *
				 * IMPORTANT:
				 * We do NOT immediately delete anything.
				 */
				batchRemoved[eventPath] = struct{}{}

				/*
				 * Rescan the parent directory if it still exists.
				 *
				 * This is what makes:
				 *
				 * old.mp3 -> new.mp3
				 *
				 * become:
				 *
				 * scan parent
				 * -> see new.mp3
				 * -> stale old.mp3 is removed
				 */
				if info, err := os.Stat(parent); err == nil && info.IsDir() {
					batchSeen[parent] = struct{}{}
				}

				batchT.Reset(batchInterval)
				continue
			}

			/*
			 * ----------------------------------------------------
			 * CREATE / WRITE
			 * ----------------------------------------------------
			 */
			if event.Op&(fsnotify.Create|fsnotify.Write) == 0 {
				continue
			}

			fileInfo, err := os.Stat(event.Name)
			if err != nil {
				continue
			}

			if fileInfo.IsDir() {
				/*
				 * New directory:
				 * scan only that directory.
				 */
				batchSeen[event.Name] = struct{}{}

				if err := filepath.WalkDir(event.Name, func(path string, d fs.DirEntry, err error) error {
					return watchCallback(watcher, path, d, err)
				}); err != nil {
					log.Printf("error watching new directory %q: %v\n", event.Name, err)
				}
			} else {
				/*
				 * New/changed file:
				 * scan only its parent directory.
				 */
				batchSeen[filepath.Dir(event.Name)] = struct{}{}
			}

			batchT.Reset(batchInterval)

		case err := <-watcher.Errors:
			log.Printf("error from watcher: %v\n", err)

		case <-ctx.Done():
			return nil
		}
	}
}
'''

s = s[:start] + new_execute_watch + s[end:]

# ============================================================
# 3. Add scoped cleanup helpers
#
# IMPORTANT:
# We use gonic's existing Track/Album deletion behavior.
# We do NOT manually delete album credits, genres, artists, etc.
# ============================================================

marker = "\nfunc (s *Scanner) cleanTracks(st *State) error {"

if marker not in s:
    raise SystemExit("PATCH ERROR: cleanTracks marker not found")

helpers = r'''
// cleanWatchTracks removes stale tracks only from albums that were
// actually visited by the filesystem watcher.
//
// This is deliberately scoped. The original cleanTracks() compares
// against the entire database and is therefore only appropriate for
// a full scan.
func (s *Scanner) cleanWatchTracks(st *State) error {
	for albumID := range st.seenAlbums {
		var all []int

		if err := s.db.
			Model(&db.Track{}).
			Where("album_id=?", albumID).
			Pluck("id", &all).
			Error; err != nil {
			return fmt.Errorf("plucking track ids for album %d: %w", albumID, err)
		}

		if len(all) == 0 {
			continue
		}

		var missing []int64

		for _, trackID := range all {
			if _, ok := st.seenTracks[trackID]; !ok {
				missing = append(missing, int64(trackID))
			}
		}

		if len(missing) == 0 {
			continue
		}

		if err := s.db.TransactionChunked(missing, func(tx *db.DB, chunk []int64) error {
			return tx.Where(chunk).Delete(&db.Track{}).Error
		}); err != nil {
			return fmt.Errorf("delete stale tracks from album %d: %w", albumID, err)
		}
	}

	return nil
}

// cleanWatchRemovedPath handles paths that really disappeared.
//
// A FILE disappearing is intentionally ignored here because its parent
// directory is rescanned and cleanWatchTracks() removes the stale Track.
//
// A DIRECTORY disappearing is different: the exact album represented by
// that directory is removed. gonic's DB schema uses ON DELETE CASCADE for
// album-owned records, so we let the existing DB behavior perform the
// dependent cleanup.
func (s *Scanner) cleanWatchRemovedPath(absPath string) error {
	musicDir, relPath := musicDirRelative(s.musicDirs, absPath)

	if musicDir == "" || relPath == "" || relPath == "." {
		return nil
	}

	/*
	 * If the path exists again, it was part of a rename/create sequence.
	 */
	if _, err := os.Stat(absPath); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("stat removed path: %w", err)
	}

	/*
	 * We need to know whether the missing path was an album directory
	 * or an individual file.
	 *
	 * The DB stores albums as:
	 *
	 *   root_dir + left_path + right_path
	 *
	 * A file has one additional filename component after the album.
	 *
	 * Therefore we first look for an exact album path.
	 */
	dir, basename := filepath.Split(relPath)

	var album db.Album

	err := s.db.
		Where(
			"root_dir=? AND left_path=? AND right_path=?",
			musicDir,
			dir,
			basename,
		).
		First(&album).
		Error

	if errors.Is(err, gorm.ErrRecordNotFound) {
		/*
		 * Not an album directory.
		 *
		 * This is normally a removed FILE. The parent directory
		 * was rescanned and cleanWatchTracks() already handles it.
		 */
		return nil
	}

	if err != nil {
		return fmt.Errorf("find removed album: %w", err)
	}

	/*
	 * Safety check:
	 *
	 * If this DB album path has children on disk, do not delete it.
	 * A transient fsnotify event must never make an existing folder
	 * disappear from gonic.
	 */
	if info, statErr := os.Stat(absPath); statErr == nil {
		if !info.IsDir() {
			return nil
		}

		return nil
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return fmt.Errorf("verify removed album: %w", statErr)
	}

	/*
	 * The exact album directory is genuinely gone.
	 *
	 * Deleting the Album relies on the same DB relationships used by
	 * gonic itself. Tracks and album metadata have ON DELETE CASCADE.
	 */
	if err := s.db.
		Where("id=?", album.ID).
		Delete(&db.Album{}).
		Error; err != nil {
		return fmt.Errorf("delete removed album %d: %w", album.ID, err)
	}

	log.Printf(
		"removed album from database: %q",
		absPath,
	)

	return nil
}
'''

s = s.replace(marker, "\n" + helpers + marker, 1)

p.write_text(s)
PY

# ============================================================
# Verify patch
# ============================================================
RUN python3 - <<'PY'
from pathlib import Path

s = Path("scanner/scanner.go").read_text()

start = s.index("func (s *Scanner) ExecuteWatch")
end = s.index("\nfunc watchCallback", start)

watch = s[start:end]

# Remove comments before checking for forbidden function calls.
import re
code_only = re.sub(r'//.*', '', watch)
code_only = re.sub(r'/\*.*?\*/', '', code_only, flags=re.S)

checks = {
    "no ScanAndClean call": "ScanAndClean(" not in code_only,
    "folder scoped scan": "s.scanCallback(st" in code_only,
    "CREATE handling": "fsnotify.Create" in code_only,
    "WRITE handling": "fsnotify.Write" in code_only,
    "REMOVE handling": "fsnotify.Remove" in code_only,
    "RENAME handling": "fsnotify.Rename" in code_only,
    "scoped track cleanup": "cleanWatchTracks(st)" in code_only,
    "removed path cleanup": "cleanWatchRemovedPath(absPath)" in code_only,
}

for name, ok in checks.items():
    if not ok:
        raise SystemExit(f"PATCH VERIFY FAILED: {name}")

if "func (s *Scanner) cleanWatchFolder" in s:
    raise SystemExit(
        "PATCH VERIFY FAILED: old dangerous cleanWatchFolder() still exists"
    )

if "func (s *Scanner) cleanWatchTracks" not in s:
    raise SystemExit(
        "PATCH VERIFY FAILED: cleanWatchTracks() missing"
    )

if "func (s *Scanner) cleanWatchRemovedPath" not in s:
    raise SystemExit(
        "PATCH VERIFY FAILED: cleanWatchRemovedPath() missing"
    )

print("PATCH VERIFY OK")
print("Watcher does not call ScanAndClean().")
print("Old cleanWatchFolder() is absent.")
print("CREATE / WRITE / REMOVE / RENAME handling present.")
print("Scoped track cleanup present.")
print("Scoped removed-path cleanup present.")
PY

# ============================================================
# Test
# ============================================================

RUN --mount=type=cache,id=gonic-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=gonic-go-build,target=/root/.cache/go-build \
    go test ./scanner ./db

# ============================================================
# Build
# ============================================================

RUN --mount=type=cache,id=gonic-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=gonic-go-build,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -o /usr/local/bin/gonic ./cmd/gonic

# ============================================================
# Final sanity check
# ============================================================

RUN ls -lh /usr/local/bin/gonic && \
    /usr/local/bin/gonic --help >/dev/null
		
# ============================================================
# MAIN IMAGE
# ============================================================

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive


# ============================================================
# SYSTEM TOOLS
# ============================================================

RUN apt-get update && apt-get install -y \
    nginx \
    apache2-utils \
    aria2 \
    xz-utils \
    file \
    7zip \
    unzip \
    cpio \
    dosfstools \
    zstd \
    ffmpeg \
    inotify-tools \
    supervisor \
    iptables \
    iproute2 \
    openssh-server \
    openssh-sftp-server \
    qemu-system-x86 \
    qemu-utils \
    fdisk \
    parted \
    curl \
    nano \
    wget \
    net-tools \
    iputils-ping \
    nmap \
    openssh-client \
    ca-certificates \
    build-essential \
    vim \
    subversion \
    pkg-config \
    libxml2-dev \
    libncurses5-dev \
    uuid-dev \
    libjansson-dev \
    libsqlite3-dev \
    libssl-dev \
    libedit-dev \
    libcurl4-openssl-dev \
    libspeexdsp-dev \
    libogg-dev \
    libvorbis-dev \
    libasound2-dev \
    portaudio19-dev \
    libopus-dev \
    libgsm1-dev \
    && rm -rf /var/lib/apt/lists/*


# ============================================================
# PHP 8.3
# FileRise requirement
# ============================================================

#RUN apt-get update && apt-get install -y \
#    software-properties-common \
#    && add-apt-repository ppa:ondrej/php \
#    && apt-get update \
#    && apt-get install -y \
#        php8.3-cli \
#        php8.3-fpm \
#        php8.3-curl \
#        php8.3-zip \
#        php8.3-xml \
#        php8.3-mbstring \
#        php8.3-gd \
#        php8.3-intl \
#        php8.3-bcmath \
#        php8.3-opcache \
#    && rm -rf /var/lib/apt/lists/*

#RUN cat > /etc/nginx/fastcgi_params <<'EOF'
#fastcgi_param QUERY_STRING       $query_string;
#fastcgi_param REQUEST_METHOD     $request_method;
#fastcgi_param CONTENT_TYPE       $content_type;
#fastcgi_param CONTENT_LENGTH     $content_length;

#fastcgi_param SCRIPT_NAME        $fastcgi_script_name;
#fastcgi_param REQUEST_URI        $request_uri;
#fastcgi_param DOCUMENT_URI       $document_uri;
#fastcgi_param DOCUMENT_ROOT     $document_root;
#fastcgi_param SERVER_PROTOCOL    $server_protocol;
#fastcgi_param REQUEST_SCHEME     $scheme;
#fastcgi_param HTTPS              $https if_not_empty;

#fastcgi_param GATEWAY_INTERFACE  CGI/1.1;
#fastcgi_param SERVER_SOFTWARE    nginx/$nginx_version;

#fastcgi_param REMOTE_ADDR        $remote_addr;
#fastcgi_param REMOTE_PORT        $remote_port;
#fastcgi_param SERVER_ADDR        $server_addr;
#fastcgi_param SERVER_PORT        $server_port;
#fastcgi_param SERVER_NAME        $server_name;

#fastcgi_param REDIRECT_STATUS    200;
#EOF

# ============================================================
# COMPOSER
# ============================================================

#RUN curl -fsSL https://getcomposer.org/installer \
#    | php -- \
#        --install-dir=/usr/local/bin \
#        --filename=composer


# ============================================================
# ASTERISK 22
# ============================================================

WORKDIR /usr/src

RUN wget https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22.11.0.tar.gz \
    && tar xzf asterisk-22.11.0.tar.gz \
    && rm asterisk-22.11.0.tar.gz

WORKDIR /usr/src/asterisk-22.11.0

RUN contrib/scripts/install_prereq

RUN ./configure --with-pjproject-bundled

RUN make menuselect.makeopts

RUN make -j$(nproc)

RUN make install \
    && make samples \
    && make config \
    && ldconfig


# ============================================================
# SSH SERVER
# ============================================================

RUN mkdir -p /var/run/sshd

RUN echo 'root:panda1208' | chpasswd

RUN sed -i \
    's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' \
    /etc/ssh/sshd_config

RUN sed -i \
    's/#Port 22/Port 2223/' \
    /etc/ssh/sshd_config


# ============================================================
# GONIC
# ============================================================
COPY --from=gonic-builder /usr/local/bin/gonic /usr/local/bin/gonic
RUN chmod +x /usr/local/bin/gonic

# ============================================================
# FILEBROWSER
# ============================================================

RUN curl -fsSL \
    https://raw.githubusercontent.com/filebrowser/get/master/get.sh \
    | bash


# ============================================================
# ADGUARD HOME
# ============================================================

RUN wget https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz \
    && tar -C /opt -xzf AdGuardHome_linux_amd64.tar.gz \
    && rm AdGuardHome_linux_amd64.tar.gz


# ============================================================
# MITMPROXY
# ============================================================

RUN wget https://downloads.mitmproxy.org/10.4.2/mitmproxy-10.4.2-linux-x86_64.tar.gz \
    && tar -C /usr/local/bin \
        -xzf mitmproxy-10.4.2-linux-x86_64.tar.gz \
    && rm mitmproxy-10.4.2-linux-x86_64.tar.gz

# ============================================================
# SLSKD BACKEND
# ============================================================

RUN mkdir -p \
        /opt/slskd \
        /var/lib/slskd \
        /home/download/soulseek \
    && useradd \
        -u 1000 \
        -g 100 \
        -M \
        -s /usr/sbin/nologin \
        slskd \
    && chown -R 1000:100 /var/lib/slskd

# PATCHED BACKEND + ALL PUBLISHED DEPENDENCIES
COPY --from=slskd-backend \
    /out/slskd/ \
    /opt/slskd/

RUN chmod +x /opt/slskd/slskd

# ============================================================
# SLSKD PATCHED WEB UI
# ============================================================

RUN rm -rf /opt/slskd/wwwroot \
    && mkdir -p /opt/slskd/wwwroot

COPY --from=slskd-web \
    /src/src/web/build/ \
    /opt/slskd/wwwroot/

RUN chown -R 1000:100 /opt/slskd/wwwroot

ENV SLSKD_APP_DIR=/var/lib/slskd

# ============================================================
# FILERISE
# ============================================================

#ARG FILERISE_VERSION=3.33.0

#WORKDIR /var/www

#RUN mkdir -p /var/www/filerise \
#    && curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
#        "https://github.com/error311/FileRise/releases/download/v${FILERISE_VERSION}/FileRise-v${FILERISE_VERSION}.zip" \
#        -o /tmp/filerise.zip \
#    && mkdir -p /tmp/filerise \
#    && unzip -q /tmp/filerise.zip -d /tmp/filerise \
#    && if [ -d "/tmp/filerise/FileRise-v${FILERISE_VERSION}" ]; then \
#           cp -a "/tmp/filerise/FileRise-v${FILERISE_VERSION}/." /var/www/filerise/; \
#       else \
#           cp -a /tmp/filerise/. /var/www/filerise/; \
#       fi \
#    && rm -rf /tmp/filerise /tmp/filerise.zip \
#    && mkdir -p \
#        /var/www/uploads \
#        /var/www/users \
#        /var/www/metadata \
#        /var/www/sessions \
#    && cd /var/www/filerise \
#    && COMPOSER_ALLOW_SUPERUSER=1 \
#        composer install \
#        --no-dev \
#        --optimize-autoloader \
#        --no-interaction \
#    && chown -R slskd:users \
#        /var/www/filerise \
#        /var/www/uploads \
#        /var/www/users \
#        /var/www/metadata \
#        /var/www/sessions \
#    && chmod -R 775 \
#        /var/www/uploads \
#        /var/www/users \
#        /var/www/metadata \
#    && chmod 700 /var/www/sessions

#RUN sed -i \
#    -e 's/^user = .*/user = slskd/' \
#    -e 's/^group = .*/group = users/' \
#    -e 's|^listen.owner = .*|listen.owner = slskd|' \
#    -e 's|^listen.group = .*|listen.group = users|' \
#    /etc/php/8.3/fpm/pool.d/www.conf \
#    && printf '\nlisten.mode = 0660\n' \
#    >> /etc/php/8.3/fpm/pool.d/www.conf
	
# ============================================================
# ASTERISK USER
# ============================================================

RUN groupadd -r asterisk \
    && useradd -r \
        -g asterisk \
        -d /var/lib/asterisk \
        -s /usr/sbin/nologin \
        asterisk


# ============================================================
# DIRECTORIES
# ============================================================

RUN mkdir -p \
        /var/log/app_logs \
        /opt/AdGuardHome/work \
        /run/asterisk \
        /var/lib/asterisk \
    && chown -R asterisk:asterisk \
        /run/asterisk \
        /var/lib/asterisk


# ============================================================
# CONTAINER STARTUP
# ============================================================

COPY container-start.sh /usr/local/bin/container-start.sh

RUN chmod +x /usr/local/bin/container-start.sh


# ============================================================
# ENTRYPOINT
# ============================================================

ENTRYPOINT ["/usr/local/bin/container-start.sh"]
