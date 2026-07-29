// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package main

import (
	"encoding/json"
	"fmt"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type SupportedApp int

const (
	Nvim SupportedApp = iota
	Emacs
)

func (e SupportedApp) String() string {
	switch e {
	case Nvim:
		return "nvim"
	case Emacs:
		return "emacs"
	default:
		return fmt.Sprintf("SupportedApp(%d)", int(e))
	}
}

var encodings = map[string]SupportedApp{"nvim": Nvim, "emacs": Emacs}

func (e *SupportedApp) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	t, ok := encodings[s]
	if !ok {
		return fmt.Errorf("unknown app: %q", s)
	}
	*e = t
	return nil
}

type AppMCPSever interface {
	Kind() SupportedApp
	NewMCPServer() *mcp.Server
	UnmarshalNotifyJSONParams(data []byte) (any, error)
}
