package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func main() {
	if len(os.Args) < 2 {
		fail(1, "Usage: fs-helper <op> [args...]")
	}
	op := os.Args[1]
	args := os.Args[2:]

	switch op {
	case "list":
		doList(args)
	case "mkdir":
		doMkdir(args)
	case "copy":
		doCopy(args)
	case "move":
		doMove(args)
	case "rename":
		doRename(args)
	case "delete":
		doDelete(args)
	case "stat":
		doStat(args)
	case "chmod":
		doChmod(args)
	case "chown":
		doChown(args)
	case "read":
		doRead(args)
	case "mkdirp":
		doMkdirp(args)
	case "write-stdin":
		doWriteStdin(args)
	case "assemble":
		doAssemble(args)
	default:
		fail(1, fmt.Sprintf("Unknown operation: %s", op))
	}
}

func writeJSON(data any) {
	b, err := json.Marshal(data)
	if err != nil {
		fail(1, err.Error())
	}
	os.Stdout.Write(b)
}

func fail(code int, msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(code)
}

func sysErrno(err error) syscall.Errno {
	var pathErr *fs.PathError
	if errors.As(err, &pathErr) {
		if e, ok := pathErr.Err.(syscall.Errno); ok {
			return e
		}
	}
	var linkErr *os.LinkError
	if errors.As(err, &linkErr) {
		if e, ok := linkErr.Err.(syscall.Errno); ok {
			return e
		}
	}
	return 0
}

func mapErr(err error) {
	switch sysErrno(err) {
	case syscall.EACCES, syscall.EPERM:
		fail(13, "EACCES")
	case syscall.ENOENT:
		fail(2, "ENOENT")
	case syscall.EEXIST, syscall.ENOTEMPTY:
		fail(17, "EEXIST")
	}
	fail(1, err.Error())
}

// uniqueDst generates a unique destination path in dstDir for src,
// trying name.ext, name (1).ext, name (2).ext, … up to 1000.
func uniqueDst(src, dstDir string) string {
	base := filepath.Base(src)
	ext := filepath.Ext(base)
	name := strings.TrimSuffix(base, ext)
	candidate := filepath.Join(dstDir, base)
	for n := 1; n <= 1000; n++ {
		if _, err := os.Lstat(candidate); os.IsNotExist(err) {
			return candidate
		}
		candidate = filepath.Join(dstDir, fmt.Sprintf("%s (%d)%s", name, n, ext))
	}
	return candidate
}

// ── list ──────────────────────────────────────────────────────────────────────

type listEntry struct {
	Name  string `json:"name"`
	Path  string `json:"path"`
	Type  string `json:"type"`
	Size  *int64 `json:"size"`
	Mtime string `json:"mtime"`
}

func doList(args []string) {
	if len(args) < 1 {
		fail(1, "list: missing directory argument")
	}
	dir := args[0]
	entries, err := os.ReadDir(dir)
	if err != nil {
		mapErr(err)
	}
	result := make([]listEntry, 0, len(entries))
	for _, e := range entries {
		full := filepath.Join(dir, e.Name())
		info, err := os.Stat(full)
		if err != nil {
			continue
		}
		le := listEntry{
			Name:  e.Name(),
			Path:  full,
			Mtime: info.ModTime().UTC().Format("2006-01-02T15:04:05.000Z07:00"),
		}
		if info.IsDir() {
			le.Type = "dir"
		} else {
			le.Type = "file"
			sz := info.Size()
			le.Size = &sz
		}
		result = append(result, le)
	}
	writeJSON(result)
}

// ── mkdir ─────────────────────────────────────────────────────────────────────

func doMkdir(args []string) {
	if len(args) < 2 {
		fail(1, "mkdir: missing arguments")
	}
	parent, name := args[0], args[1]
	if name == "" {
		name = "New Folder"
	}
	target := filepath.Join(parent, name)
	for n := 1; n <= 1000; n++ {
		if _, err := os.Lstat(target); os.IsNotExist(err) {
			break
		}
		target = filepath.Join(parent, fmt.Sprintf("%s (%d)", name, n))
	}
	if err := os.MkdirAll(target, 0755); err != nil {
		mapErr(err)
	}
	writeJSON(map[string]string{"path": target, "name": filepath.Base(target)})
}

// ── copy ──────────────────────────────────────────────────────────────────────

func doCopy(args []string) {
	if len(args) < 2 {
		fail(1, "copy: missing arguments")
	}
	src, dstDir := args[0], args[1]
	dst := uniqueDst(src, dstDir)
	if err := copyAll(src, dst); err != nil {
		mapErr(err)
	}
	writeJSON(map[string]any{"ok": true, "dst": dst})
}

func copyAll(src, dst string) error {
	info, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return copyDir(src, dst, info)
	}
	return copyFile(src, dst, info)
}

func copyFile(src, dst string, info fs.FileInfo) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	outF, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode())
	if err != nil {
		return err
	}
	if _, err := io.Copy(outF, in); err != nil {
		outF.Close()
		return err
	}
	return outF.Close()
}

func copyDir(src, dst string, info fs.FileInfo) error {
	if err := os.MkdirAll(dst, info.Mode()); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		s := filepath.Join(src, e.Name())
		d := filepath.Join(dst, e.Name())
		ei, err := e.Info()
		if err != nil {
			return err
		}
		if e.IsDir() {
			if err := copyDir(s, d, ei); err != nil {
				return err
			}
		} else {
			if err := copyFile(s, d, ei); err != nil {
				return err
			}
		}
	}
	return nil
}

// ── move ──────────────────────────────────────────────────────────────────────

func doMove(args []string) {
	if len(args) < 2 {
		fail(1, "move: missing arguments")
	}
	src, dstDir := args[0], args[1]
	dst := filepath.Join(dstDir, filepath.Base(src))
	if _, err := os.Lstat(dst); err == nil {
		fail(17, "EEXIST")
	}
	err := os.Rename(src, dst)
	if err != nil {
		if sysErrno(err) == syscall.EXDEV {
			if err2 := copyAll(src, dst); err2 != nil {
				mapErr(err2)
			}
			if err2 := os.RemoveAll(src); err2 != nil {
				mapErr(err2)
			}
		} else {
			mapErr(err)
		}
	}
	writeJSON(map[string]any{"ok": true, "dst": dst})
}

// ── rename ────────────────────────────────────────────────────────────────────

func doRename(args []string) {
	if len(args) < 2 {
		fail(1, "rename: missing arguments")
	}
	path, newName := args[0], args[1]
	dst := filepath.Join(filepath.Dir(path), newName)
	if _, err := os.Lstat(dst); err == nil {
		fail(17, "EEXIST")
	}
	if err := os.Rename(path, dst); err != nil {
		mapErr(err)
	}
	writeJSON(map[string]any{"ok": true, "dst": dst})
}

// ── delete ────────────────────────────────────────────────────────────────────

func doDelete(args []string) {
	if len(args) < 1 {
		fail(1, "delete: missing path argument")
	}
	if err := os.RemoveAll(args[0]); err != nil {
		mapErr(err)
	}
	writeJSON(map[string]bool{"ok": true})
}

// ── stat ──────────────────────────────────────────────────────────────────────

func doStat(args []string) {
	if len(args) < 1 {
		fail(1, "stat: missing path argument")
	}
	path := args[0]
	info, err := os.Lstat(path)
	if err != nil {
		mapErr(err)
	}
	sys := info.Sys().(*syscall.Stat_t)
	uid := int(sys.Uid)
	gid := int(sys.Gid)
	mode := fmt.Sprintf("%03o", info.Mode().Perm())

	owner := strconv.Itoa(uid)
	if u, err := user.LookupId(strconv.Itoa(uid)); err == nil {
		owner = u.Username
	}
	group := strconv.Itoa(gid)
	if g, err := user.LookupGroupId(strconv.Itoa(gid)); err == nil {
		group = g.Name
	}

	typ := "file"
	if info.IsDir() {
		typ = "dir"
	}
	var size *int64
	if !info.IsDir() {
		sz := info.Size()
		size = &sz
	}

	writeJSON(map[string]any{
		"mode":  mode,
		"owner": owner,
		"group": group,
		"uid":   uid,
		"gid":   gid,
		"type":  typ,
		"size":  size,
	})
}

// ── read ──────────────────────────────────────────────────────────────────────

func doRead(args []string) {
	if len(args) < 1 {
		fail(1, "read: missing path argument")
	}
	f, err := os.Open(args[0])
	if err != nil {
		mapErr(err)
	}
	defer f.Close()
	if _, err := io.Copy(os.Stdout, f); err != nil {
		fail(1, err.Error())
	}
}

// ── mkdirp ────────────────────────────────────────────────────────────────────

func doMkdirp(args []string) {
	if len(args) < 1 {
		fail(1, "mkdirp: missing path argument")
	}
	if err := os.MkdirAll(args[0], 0755); err != nil {
		mapErr(err)
	}
	writeJSON(map[string]bool{"ok": true})
}

// ── write-stdin ───────────────────────────────────────────────────────────────

func doWriteStdin(args []string) {
	if len(args) < 1 {
		fail(1, "write-stdin: missing path argument")
	}
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fail(1, err.Error())
	}
	if err := os.WriteFile(args[0], data, 0644); err != nil {
		mapErr(err)
	}
	writeJSON(map[string]bool{"ok": true})
}

// ── assemble ──────────────────────────────────────────────────────────────────

func doAssemble(args []string) {
	if len(args) < 2 {
		fail(1, "assemble: need <destFile> <part0> [part1 ...]")
	}
	destFile := args[0]
	parts := args[1:]
	out, err := os.OpenFile(destFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		mapErr(err)
	}
	defer out.Close()
	for _, part := range parts {
		f, err := os.Open(part)
		if err != nil {
			mapErr(err)
		}
		_, cpErr := io.Copy(out, f)
		f.Close()
		if cpErr != nil {
			fail(1, cpErr.Error())
		}
	}
	writeJSON(map[string]bool{"ok": true})
}

// ── chmod ─────────────────────────────────────────────────────────────────────

func doChmod(args []string) {
	if len(args) < 2 {
		fail(1, "chmod: missing arguments")
	}
	modeStr, path := args[0], args[1]
	mode, err := strconv.ParseUint(modeStr, 8, 32)
	if err != nil {
		fail(1, fmt.Sprintf("chmod: invalid mode %q", modeStr))
	}
	if err := os.Chmod(path, fs.FileMode(mode)); err != nil {
		mapErr(err)
	}
	writeJSON(map[string]bool{"ok": true})
}

// ── chown ─────────────────────────────────────────────────────────────────────

func doChown(args []string) {
	if len(args) < 3 {
		fail(1, "chown: missing arguments")
	}
	ownerStr, groupStr, path := args[0], args[1], args[2]

	uid := -1
	if n, err := strconv.Atoi(ownerStr); err == nil {
		uid = n
	} else if u, err := user.Lookup(ownerStr); err == nil {
		if n, err := strconv.Atoi(u.Uid); err == nil {
			uid = n
		}
	} else {
		fail(1, fmt.Sprintf("chown: unknown user %q", ownerStr))
	}

	gid := -1
	if n, err := strconv.Atoi(groupStr); err == nil {
		gid = n
	} else if g, err := user.LookupGroup(groupStr); err == nil {
		if n, err := strconv.Atoi(g.Gid); err == nil {
			gid = n
		}
	} else {
		fail(1, fmt.Sprintf("chown: unknown group %q", groupStr))
	}

	if err := os.Lchown(path, uid, gid); err != nil {
		mapErr(err)
	}
	writeJSON(map[string]bool{"ok": true})
}
