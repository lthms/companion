// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Maintainer: Sylvain Ribstein <sylvain.ribstein@gmail.com>

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// EmacsMCPServer drives a running Emacs through emacsclient. Each operation is
// one `emacsclient --eval '(sidekick--rpc "<base64 json>")'` invocation; the
// elisp side (emacs/sidekick.el) dispatches on the "op" field and replies
// with base64-encoded JSON. Base64 in both directions sidesteps elisp/shell
// string-escaping entirely — base64's alphabet needs no quoting anywhere.
//
// Buffers are identified by their (unique) buffer name. Line ranges follow the
// nvim API convention: start is 0-based inclusive, end is 0-based exclusive,
// and end == -1 means "through the last line".
type EmacsMCPServer struct {
	socket string
	// root is this session's project directory, reported as the cwd. Emacs has
	// no per-session cwd, and a daemon shared by several emacsclients drives
	// one socket for every project, so the root is pinned here at registration
	// rather than read back from Emacs — that is what keeps each
	// project-scoped session reporting its own working directory.
	root string
}

// emacsRequest is the base64-encoded JSON payload sent to sidekick--rpc. Only
// the fields relevant to a given op are populated; the elisp dispatcher reads
// what it needs per op.
type emacsRequest struct {
	Op     string   `json:"op"`
	Buf    string   `json:"buf"`
	Path   string   `json:"path"`
	Start  int      `json:"start"`
	End    int      `json:"end"`
	Lines  []string `json:"lines"`
	Line   int      `json:"line"`
	Col    int      `json:"col"`
	Symbol string   `json:"symbol"`
	// ask: Prompt is the question put to the user, Choices the selectable
	// answers offered in the minibuffer.
	Prompt  string   `json:"prompt"`
	Choices []string `json:"choices"`
}

type emacsBuf struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (self *EmacsMCPServer) call(req emacsRequest, out any) error {
	payload, err := json.Marshal(req)
	if err != nil {
		return err
	}

	expr := fmt.Sprintf("(sidekick--rpc %q)", base64.StdEncoding.EncodeToString(payload))
	raw, err := exec.Command("emacsclient", "-s", self.socket, "--eval", expr).Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return fmt.Errorf("emacsclient %s: %s", req.Op, strings.TrimSpace(string(exitErr.Stderr)))
		}
		return fmt.Errorf("emacsclient %s: %w", req.Op, err)
	}

	// emacsclient prints the evaluated value: an elisp string literal holding
	// the base64 reply, e.g. "eyJvayI6dHJ1ZX0=" (quotes included).
	reply := strings.Trim(strings.TrimSpace(string(raw)), `"`)
	decoded, err := base64.StdEncoding.DecodeString(reply)
	if err != nil {
		return fmt.Errorf("emacsclient %s: unexpected reply %q", req.Op, strings.TrimSpace(string(raw)))
	}

	var fail struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(decoded, &fail); err == nil && fail.Error != "" {
		return fmt.Errorf("emacs %s: %s", req.Op, fail.Error)
	}

	if out == nil {
		return nil
	}
	return json.Unmarshal(decoded, out)
}

func (self *EmacsMCPServer) cwd() (string, error) {
	return self.root, nil
}

func (self *EmacsMCPServer) buffers(op string) ([]emacsBuf, error) {
	var resp struct {
		Buffers []emacsBuf `json:"buffers"`
	}
	if err := self.call(emacsRequest{Op: op}, &resp); err != nil {
		return nil, err
	}
	return resp.Buffers, nil
}

func (self *EmacsMCPServer) readLines(buf string, start, end int) ([]string, error) {
	var resp struct {
		Lines []string `json:"lines"`
	}
	err := self.call(emacsRequest{Op: "read-lines", Buf: buf, Start: start, End: end}, &resp)
	return resp.Lines, err
}

type EmacsReadBufferInput struct {
	Buffer string `json:"buffer" jsonschema:"the emacs buffer name to read"`
	Start  *int   `json:"start,omitempty" jsonschema:"first line to read, 1-based inclusive; omit to start at the top"`
	End    *int   `json:"end,omitempty" jsonschema:"last line to read, 1-based inclusive; omit to read to the end"`
}

type EmacsWriteBufferInput struct {
	Buffer  string `json:"buffer" jsonschema:"the emacs buffer name to write"`
	Content string `json:"content" jsonschema:"the replacement content; lines are separated by \\n"`
	Start   *int   `json:"start,omitempty" jsonschema:"first line to replace, 1-based inclusive; omit (with end) to replace the whole buffer"`
	End     *int   `json:"end,omitempty" jsonschema:"last line to replace, 1-based inclusive; use start-1 to insert before start without removing any line"`
}

type EmacsSaveBufferInput struct {
	Buffer string `json:"buffer" jsonschema:"the emacs buffer name to save to disk"`
}

type EmacsJumpInput struct {
	Buffer string `json:"buffer" jsonschema:"the emacs buffer name to make active in the selected window"`
	Line   int    `json:"line" jsonschema:"1-based line to place the cursor on"`
	Column *int   `json:"column,omitempty" jsonschema:"1-based column to place the cursor on; defaults to 1"`
}

func (self *EmacsMCPServer) readBuffer(_ context.Context, _ *mcp.CallToolRequest, in EmacsReadBufferInput) (*mcp.CallToolResult, any, error) {
	start := 0
	if in.Start != nil {
		start = max(*in.Start-1, 0)
	}
	end := -1
	if in.End != nil {
		end = *in.End
	}

	lines, err := self.readLines(in.Buffer, start, end)
	if err != nil {
		return nil, nil, fmt.Errorf("read buffer %s: %w", in.Buffer, err)
	}

	var b strings.Builder
	for i, l := range lines {
		fmt.Fprintf(&b, "%6d\t%s\n", start+i+1, l)
	}

	return textResult(b.String()), nil, nil
}

func (self *EmacsMCPServer) writeBuffer(_ context.Context, _ *mcp.CallToolRequest, in EmacsWriteBufferInput) (*mcp.CallToolResult, any, error) {
	start, end := 0, -1
	if in.Start != nil || in.End != nil {
		if in.Start == nil || in.End == nil {
			return nil, nil, fmt.Errorf("start and end must be provided together")
		}
		start = max(*in.Start-1, 0)
		end = *in.End
	}

	// Empty content deletes the range (or empties the buffer); otherwise split
	// into lines. An empty replacement is a deletion. A single trailing newline
	// marks the last line's EOL rather than an extra empty line, so strip one
	// before splitting — otherwise "A\nB\n" would yield three lines.
	replacement := []string{}
	if in.Content != "" {
		replacement = strings.Split(strings.TrimSuffix(in.Content, "\n"), "\n")
	}

	if err := self.call(emacsRequest{Op: "set-lines", Buf: in.Buffer, Start: start, End: end, Lines: replacement}, nil); err != nil {
		return nil, nil, fmt.Errorf("write buffer %s: %w", in.Buffer, err)
	}

	return textResult(fmt.Sprintf("wrote %d lines to buffer %s", len(replacement), in.Buffer)), nil, nil
}

// emacsBufRef pairs an opened buffer with its path relative to the session cwd.
type emacsBufRef struct {
	id  string
	rel string
}

// openBuffers returns the loaded, file-backed buffers, each name expressed
// relative to the session cwd. If include is non-nil, only buffers whose
// relative path matches it are returned. These are the buffers glob and grep
// operate over.
func (self *EmacsMCPServer) openBuffers(include *regexp.Regexp) ([]emacsBufRef, error) {
	root, err := self.cwd()
	if err != nil {
		return nil, err
	}

	bufs, err := self.buffers("open-file-buffers")
	if err != nil {
		return nil, err
	}

	var refs []emacsBufRef
	for _, buf := range bufs {
		rel := buf.Name
		if r, err := filepath.Rel(root, buf.Name); err == nil {
			rel = r
		}
		// Scope to the session's project. A shared Emacs (daemon) lists buffers
		// from every project, so drop any whose file lives outside this
		// session's root — a failed Rel (rel unchanged, still absolute) or a
		// ".." prefix both mean "not under root".
		if root != "" && (rel == buf.Name || strings.HasPrefix(rel, "..")) {
			continue
		}
		if include != nil && !include.MatchString(rel) {
			continue
		}

		refs = append(refs, emacsBufRef{id: buf.ID, rel: rel})
	}
	return refs, nil
}

func (self *EmacsMCPServer) glob(_ context.Context, _ *mcp.CallToolRequest, in GlobInput) (*mcp.CallToolResult, any, error) {
	re, err := globToRegexp(in.Pattern)
	if err != nil {
		return nil, nil, fmt.Errorf("invalid pattern %q: %w", in.Pattern, err)
	}

	refs, err := self.openBuffers(re)
	if err != nil {
		return nil, nil, err
	}

	if len(refs) == 0 {
		return textResult("no matches"), nil, nil
	}

	var matches []string
	for _, ref := range refs {
		matches = append(matches, ref.rel)
	}
	return textResult(strings.Join(matches, "\n")), nil, nil
}

func (self *EmacsMCPServer) grep(_ context.Context, _ *mcp.CallToolRequest, in GrepInput) (*mcp.CallToolResult, any, error) {
	re, err := regexp.Compile(in.Pattern)
	if err != nil {
		return nil, nil, fmt.Errorf("invalid pattern %q: %w", in.Pattern, err)
	}

	var include *regexp.Regexp
	if in.Include != "" {
		include, err = globToRegexp(in.Include)
		if err != nil {
			return nil, nil, fmt.Errorf("invalid include %q: %w", in.Include, err)
		}
	}

	refs, err := self.openBuffers(include)
	if err != nil {
		return nil, nil, err
	}

	const maxMatches = 500
	var out []string
	for _, ref := range refs {
		lines, err := self.readLines(ref.id, 0, -1)
		if err != nil {
			return nil, nil, fmt.Errorf("read buffer %s: %w", ref.id, err)
		}
		for n, line := range lines {
			if re.MatchString(line) {
				out = append(out, fmt.Sprintf("%s:%d:%s", ref.rel, n+1, line))
				if len(out) >= maxMatches {
					break
				}
			}
		}
		if len(out) >= maxMatches {
			break
		}
	}

	if len(out) == 0 {
		return textResult("no matches"), nil, nil
	}
	text := strings.Join(out, "\n")
	if len(out) >= maxMatches {
		text += fmt.Sprintf("\n(truncated at %d matches)", maxMatches)
	}
	return textResult(text), nil, nil
}

func (self *EmacsMCPServer) listBuffers(_ context.Context, _ *mcp.CallToolRequest, _ ListBuffersInput) (*mcp.CallToolResult, any, error) {
	bufs, err := self.buffers("list-buffers")
	if err != nil {
		return nil, nil, err
	}

	var b strings.Builder
	for _, buf := range bufs {
		name := buf.Name
		if name == "" {
			name = "[No Name]"
		}
		fmt.Fprintf(&b, "%s\t%s\n", buf.ID, name)
	}

	if b.Len() == 0 {
		return textResult("no buffers"), nil, nil
	}
	return textResult(b.String()), nil, nil
}

func (self *EmacsMCPServer) openBuffer(_ context.Context, _ *mcp.CallToolRequest, in OpenBufferInput) (*mcp.CallToolResult, any, error) {
	path := in.Path
	if !filepath.IsAbs(path) {
		dir, err := self.cwd()
		if err != nil {
			return nil, nil, err
		}
		path = filepath.Join(dir, path)
	}

	if _, err := os.Stat(path); err != nil {
		return nil, nil, fmt.Errorf("open buffer: %w", err)
	}

	var resp struct {
		ID string `json:"id"`
	}
	if err := self.call(emacsRequest{Op: "open", Path: path}, &resp); err != nil {
		return nil, nil, err
	}

	return textResult(fmt.Sprintf("buffer %s\t%s", resp.ID, path)), nil, nil
}

func (self *EmacsMCPServer) saveBuffer(_ context.Context, _ *mcp.CallToolRequest, in EmacsSaveBufferInput) (*mcp.CallToolResult, any, error) {
	if err := self.call(emacsRequest{Op: "save", Buf: in.Buffer}, nil); err != nil {
		return nil, nil, fmt.Errorf("save buffer %s: %w", in.Buffer, err)
	}

	return textResult(fmt.Sprintf("saved buffer %s", in.Buffer)), nil, nil
}

func (self *EmacsMCPServer) jump(_ context.Context, _ *mcp.CallToolRequest, in EmacsJumpInput) (*mcp.CallToolResult, any, error) {
	col := 1
	if in.Column != nil {
		col = *in.Column
	}

	if err := self.call(emacsRequest{Op: "jump", Buf: in.Buffer, Line: in.Line, Col: col}, nil); err != nil {
		return nil, nil, fmt.Errorf("jump to buffer %s: %w", in.Buffer, err)
	}

	return textResult(fmt.Sprintf("jumped to buffer %s at %d:%d (M-, returns)", in.Buffer, in.Line, col)), nil, nil
}

// EmacsXrefInput locates the identifier an xref query runs on. Emacs's xref
// backends (eglot/lsp-mode, etags, the elisp backend, …) resolve symbols
// semantically, so this is what glob/grep can't do: follow a name to where
// it's defined or used.
type EmacsXrefInput struct {
	Buffer string `json:"buffer" jsonschema:"the emacs buffer name containing the identifier"`
	Line   int    `json:"line" jsonschema:"1-based line the identifier is on"`
	Column *int   `json:"column,omitempty" jsonschema:"1-based column landing on the identifier; defaults to 1. Point must sit on the symbol for the xref backend to resolve it"`
	Symbol string `json:"symbol,omitempty" jsonschema:"identifier to look up; defaults to the symbol at line:column. Position-based backends (eglot/lsp) ignore this and always use line:column"`
}

// emacsLocation is one result of an xref query: a file-backed definition or
// reference site.
type emacsLocation struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Summary string `json:"summary"`
}

// xref runs op ("find-definition" or "find-references") at the requested point
// and renders the resulting locations as "path:line: summary" lines, with the
// path relative to the session cwd (like grep) when it can be.
func (self *EmacsMCPServer) xref(op string, in EmacsXrefInput) (*mcp.CallToolResult, any, error) {
	col := 1
	if in.Column != nil {
		col = *in.Column
	}

	var resp struct {
		Locations []emacsLocation `json:"locations"`
	}
	if err := self.call(emacsRequest{Op: op, Buf: in.Buffer, Line: in.Line, Col: col, Symbol: in.Symbol}, &resp); err != nil {
		return nil, nil, err
	}

	if len(resp.Locations) == 0 {
		return textResult("no results"), nil, nil
	}

	// Relativize paths against the session cwd for readability; fall back to
	// absolute paths if the cwd lookup fails.
	root, _ := self.cwd()

	const maxLocations = 200
	var out []string
	for i, loc := range resp.Locations {
		if i >= maxLocations {
			break
		}
		path := loc.File
		if root != "" {
			if rel, err := filepath.Rel(root, loc.File); err == nil {
				path = rel
			}
		}
		out = append(out, fmt.Sprintf("%s:%d:\t%s", path, loc.Line, loc.Summary))
	}

	text := strings.Join(out, "\n")
	if len(resp.Locations) > maxLocations {
		text += fmt.Sprintf("\n(truncated at %d results)", maxLocations)
	}
	return textResult(text), nil, nil
}

func (self *EmacsMCPServer) findDefinition(_ context.Context, _ *mcp.CallToolRequest, in EmacsXrefInput) (*mcp.CallToolResult, any, error) {
	return self.xref("find-definition", in)
}

func (self *EmacsMCPServer) findReferences(_ context.Context, _ *mcp.CallToolRequest, in EmacsXrefInput) (*mcp.CallToolResult, any, error) {
	return self.xref("find-references", in)
}

type EmacsDiagnosticsInput struct {
	Buffer string `json:"buffer" jsonschema:"the emacs buffer name to report diagnostics for"`
}

// emacsDiagnostic is one flycheck/flymake report line.
type emacsDiagnostic struct {
	Line     int    `json:"line"`
	Column   int    `json:"column"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
}

func (self *EmacsMCPServer) diagnostics(_ context.Context, _ *mcp.CallToolRequest, in EmacsDiagnosticsInput) (*mcp.CallToolResult, any, error) {
	var resp struct {
		Diagnostics []emacsDiagnostic `json:"diagnostics"`
	}
	if err := self.call(emacsRequest{Op: "diagnostics", Buf: in.Buffer}, &resp); err != nil {
		return nil, nil, fmt.Errorf("diagnostics for %s: %w", in.Buffer, err)
	}

	if len(resp.Diagnostics) == 0 {
		return textResult("no diagnostics"), nil, nil
	}

	// The checker reports in no guaranteed order; sort by position so the
	// output reads top-to-bottom like the buffer.
	sort.SliceStable(resp.Diagnostics, func(i, j int) bool {
		a, b := resp.Diagnostics[i], resp.Diagnostics[j]
		if a.Line != b.Line {
			return a.Line < b.Line
		}
		return a.Column < b.Column
	})

	var out []string
	for _, d := range resp.Diagnostics {
		out = append(out, fmt.Sprintf("%d:%d: %s: %s", d.Line, d.Column, d.Severity, d.Message))
	}
	return textResult(strings.Join(out, "\n")), nil, nil
}

// EmacsAskInput is a multiple-choice question put to the user. Emacs renders
// the choices in the minibuffer and blocks until one is picked; the pick comes
// back as the tool result. Use this to let the user decide instead of guessing.
type EmacsAskInput struct {
	Question string   `json:"question" jsonschema:"the question to put to the user"`
	Choices  []string `json:"choices" jsonschema:"the selectable answers to offer; the user picks exactly one"`
}

func (self *EmacsMCPServer) ask(_ context.Context, _ *mcp.CallToolRequest, in EmacsAskInput) (*mcp.CallToolResult, any, error) {
	if len(in.Choices) == 0 {
		return nil, nil, fmt.Errorf("ask requires at least one choice")
	}

	var resp struct {
		Answer string `json:"answer"`
	}
	if err := self.call(emacsRequest{Op: "ask", Prompt: in.Question, Choices: in.Choices}, &resp); err != nil {
		return nil, nil, fmt.Errorf("ask user: %w", err)
	}

	return textResult(resp.Answer), nil, nil
}

func (self *EmacsMCPServer) Kind() SupportedApp {
	return Emacs
}

func (self *EmacsMCPServer) NewMCPServer() *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    "sidekick for emacs",
		Version: "0.1.0",
	}, nil)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "read_buffer",
		Description: "Read an emacs buffer, optionally a line range. Output is prefixed with 1-based line numbers (like cat -n). The buffer id is the emacs buffer name reported by the /listen monitor as the \"buf\" field.",
	}, self.readBuffer)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "write_buffer",
		Description: "Write content into an emacs buffer. With no line range, replaces the whole buffer; with start/end (1-based, inclusive), replaces only that range — set them equal to insert-replace a single line, or end = start-1 to insert without removing. The buffer id is the buffer name from /listen.",
	}, self.writeBuffer)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "glob",
		Description: "List the session's opened (file-backed) buffers whose path matches a glob pattern. Paths are matched relative to the emacs session's working directory: * and ? stay within a path segment, ** spans segments, and a leading \"**/\" matches zero or more directories (so \"**/*.go\" matches both main.go and src/foo.go). Only opened buffers are considered — it does not walk the filesystem. Use open_buffer first to bring a file into scope.",
	}, self.glob)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "grep",
		Description: "Search the contents of the session's opened (file-backed) buffers with a regular expression. Optionally restrict to buffers whose path matches an include glob (relative to the session's working directory). Only opened buffers are searched — it does not walk the filesystem; use open_buffer first to bring a file into scope. Returns path:line:text.",
	}, self.grep)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "list_buffers",
		Description: "List the emacs session's buffers as \"name<TAB>path\" lines. Use the buffer name with read_buffer/write_buffer.",
	}, self.listBuffers)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "open_buffer",
		Description: "Open a file as an emacs buffer so it can be read/written, without changing the active buffer or window. Path may be relative to the session's working directory. Returns the new buffer name. Use this instead of the Read/Write tools when a file you need isn't already a buffer.",
	}, self.openBuffer)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "save_buffer",
		Description: "Save (write to disk) an emacs buffer, like save-buffer. Use after write_buffer to persist changes. The buffer id is the buffer name reported by the /listen monitor.",
	}, self.saveBuffer)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "jump",
		Description: "Make a buffer the active buffer in the selected window and move the cursor to a line (and optional column). Pushes the prior location onto the xref marker stack first, so the user can press M-, (xref-go-back) to jump back — use this to take the user to a location you found (e.g. \"the function doing X\"). The buffer id is the buffer name from /listen, or from open_buffer/list_buffers.",
	}, self.jump)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "find_definition",
		Description: "Find where the symbol at a buffer location is defined, using Emacs's xref backend (LSP via eglot/lsp-mode, etags, the elisp backend, …). Put line/column on the identifier. Returns path:line: summary for each definition. Prefer this over grep for \"where is X defined\" — it understands the language, not just the text.",
	}, self.findDefinition)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "find_references",
		Description: "Find where the symbol at a buffer location is referenced, using Emacs's xref backend. Put line/column on the identifier. Returns path:line: summary for each use site. Prefer this over grep for \"who calls X\" — it resolves the symbol semantically rather than matching text.",
	}, self.findReferences)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "buffer_diagnostics",
		Description: "List the diagnostics (errors, warnings, notes) Emacs already knows about for a buffer, from flycheck or flymake — the same problems shown in the buffer. Returns line:column: severity: message. Use it to see what a checker/LSP reports before and after your edits, instead of running an external build.",
	}, self.diagnostics)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "ask",
		Description: "Put a multiple-choice question to the user in Emacs and get their pick back. Emacs shows the choices in the minibuffer (completing-read) and this call blocks until the user selects one; the selected string is returned as the result. Use it whenever you would otherwise guess between concrete alternatives — offer the options and let the user decide.",
	}, self.ask)

	return server
}

type EmacsNotifyParams struct {
	Buf  string `json:"buf"`
	File string `json:"file"`
	// Region is the active selection at notify time, formatted as
	// "FILE:beg-end" plus the fenced snippet (see sidekick--region-context),
	// or empty when nothing was selected. Re-broadcast verbatim on /listen.
	Region string `json:"region,omitempty"`
}

func (self *EmacsMCPServer) UnmarshalNotifyJSONParams(data []byte) (any, error) {
	var r EmacsNotifyParams
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, err
	}

	return r, nil
}
