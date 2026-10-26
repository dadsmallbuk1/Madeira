// The mod manager's archive reader (build/libarchive-ios/mod_archive.c, built
// with libarchive into libmadeira_archive.a): unpacks a zip, 7z or rar mod.

#ifndef ModArchive_h
#define ModArchive_h

#include <stddef.h>
#include <stdint.h>

/// Called after each file with the number of files written so far and the
/// bytes unpacked so far. Return non-zero to stop the extraction.
typedef int (*mod_archive_progress_fn)(void *context, int64_t files, int64_t bytes);

/// Unpack every regular file of `archive_path` under `dest_dir` (created if
/// needed). Backslashes in names become folders; absolute names, "..", links
/// and devices are skipped. Returns 0 on success; otherwise non-zero with a
/// message in `error` (1: could not read, 2: password-protected,
/// 3: could not write, 4: stopped by the progress callback).
int mod_archive_extract(const char *archive_path, const char *dest_dir,
                        mod_archive_progress_fn progress, void *context,
                        char *error, size_t error_size);

#endif
