// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strconv"

	"github.com/alecthomas/kong"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var cli struct {
	Port int `help:"Port to listen on." short:"p" default:"8000" env:"SIDEKICK_PORT"`
}

func main() {
	kong.Parse(&cli, kong.Name("sidekick"),
		kong.Description("sidekick daemon"))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ln, err := listen()
	if err != nil {
		slog.Error("cannot listen", "err", err)
		os.Exit(1)
	}

	srv := &http.Server{Handler: newRPCHandler()}
	context.AfterFunc(ctx, func() { _ = srv.Shutdown(context.Background()) })

	slog.Info("sidekick server listening", "addr", ln.Addr())
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

// listen returns the socket to serve on. Under systemd socket activation,
// systemd binds the socket, passes it as the first descriptor (systemd's
// SD_LISTEN_FDS_START is 3), and sets LISTEN_PID/LISTEN_FDS; adopting that
// listener means :8000 is accepting the instant `systemctl start' returns, so
// the editor's `register' can never race the bind (systemd queues the
// connection until we accept). Run standalone (`./sidekick'), no descriptors
// are passed and we bind cli.Port ourselves, as before.
func listen() (net.Listener, error) {
	if os.Getenv("LISTEN_PID") == strconv.Itoa(os.Getpid()) {
		if nfds, err := strconv.Atoi(os.Getenv("LISTEN_FDS")); err == nil && nfds >= 1 {
			return net.FileListener(os.NewFile(3, "sidekick.socket"))
		}
	}
	return net.Listen("tcp", fmt.Sprintf(":%d", cli.Port))
}

func newRPCHandler() http.Handler {
	registry := newRegistry()
	handleMCP := mcp.NewStreamableHTTPHandler(func(r *http.Request) *mcp.Server {
		pid, _ := strconv.Atoi(r.PathValue("pid"))
		mcp, _ := registry.mcp(pid)
		return mcp.NewMCPServer()
	}, &mcp.StreamableHTTPOptions{Stateless: true})

	mux := http.NewServeMux()
	mux.HandleFunc("POST /{$}", handleRPC(registry))
	mux.Handle("POST /mcp/{pid}", handleMCP)
	mux.HandleFunc("GET /listen/{pid}", handleListen(registry))

	return mux
}
