// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/go-playground/validator/v10"
	"github.com/sourcegraph/jsonrpc2"
)

type handlers struct {
	m map[string]rpcHandler
}

func new() handlers {
	return handlers{
		m: map[string]rpcHandler{},
	}
}

func set[T any, U any](self *handlers, method string, fn func(context.Context, T, *registry) (U, *jsonrpc2.Error)) {
	self.m[method] = typed(fn)
}

type registerRequestShared struct {
	PID int          `json:"pid" validate:"required"`
	App SupportedApp `json:"app" validate:"required"`
}

type nvimRegisterParams struct {
	Endpoint string `json:"endpoint" validate:"required"`
}

type emacsRegisterParams struct {
	Socket string `json:"socket" validate:"required"`
	Root   string `json:"root" validate:"required"`
}

type registerRequest struct {
	PID    int
	Server AppMCPSever
}

func (req *registerRequest) UnmarshalJSON(data []byte) error {
	var shrd registerRequestShared
	if err := json.Unmarshal(data, &shrd); err != nil {
		return err
	}

	req.PID = shrd.PID

	switch shrd.App {
	case Nvim:
		var params nvimRegisterParams
		if err := json.Unmarshal(data, &params); err != nil {
			return err
		}

		req.Server = &NvimMCPServer{endpoint: params.Endpoint}
	case Emacs:
		var params emacsRegisterParams
		if err := json.Unmarshal(data, &params); err != nil {
			return err
		}

		req.Server = &EmacsMCPServer{socket: params.Socket, root: params.Root}
	}

	return nil
}

type registerResponse struct {
	Ok bool `json:"ok"`
}

func handleRegister(_ context.Context, p registerRequest, reg *registry) (registerResponse, *jsonrpc2.Error) {
	slog.Info("registered new app", "pid", p.PID, "kind", p.Server.Kind())
	reg.remember(p.PID, p.Server)
	return registerResponse{Ok: true}, nil
}

type notifyRequestShared struct {
	PID int `json:"pid" validate:"required"`
}

type notifyRequest struct {
	PID       int
	rawParams []byte
}

func (r *notifyRequest) UnmarshalJSON(data []byte) error {
	var shrd notifyRequestShared
	if err := json.Unmarshal(data, &shrd); err != nil {
		return err
	}

	r.PID = shrd.PID
	r.rawParams = data

	return nil
}

func handleNotify(_ context.Context, p notifyRequest, reg *registry) (any, *jsonrpc2.Error) {
	slog.Info("received a notification to forward", "pid", p.PID)
	mcp, _ := reg.mcp(p.PID)
	payload, _ := mcp.UnmarshalNotifyJSONParams(p.rawParams)
	reg.notify(p.PID, payload)

	return nil, nil
}

func handleRPC(reg *registry) func(http.ResponseWriter, *http.Request) {
	hs := new()
	set(&hs, "register", handleRegister)
	set(&hs, "notify", handleNotify)

	return func(w http.ResponseWriter, r *http.Request) {
		var req jsonrpc2.Request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeRPCResponse(w, &jsonrpc2.Response{
				Error: &jsonrpc2.Error{Code: jsonrpc2.CodeParseError, Message: err.Error()},
			})
			return
		}

		result, rpcErr := hs.dispatch(r.Context(), &req, reg)

		if req.Notif {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		resp := &jsonrpc2.Response{ID: req.ID}
		if rpcErr != nil {
			resp.Error = rpcErr
		} else {
			resp.Result = &result
		}
		writeRPCResponse(w, resp)
	}
}

type rpcHandler func(context.Context, *jsonrpc2.Request, *registry) (json.RawMessage, *jsonrpc2.Error)

func typed[T any, U any](fn func(context.Context, T, *registry) (U, *jsonrpc2.Error)) rpcHandler {
	return func(ctx context.Context, req *jsonrpc2.Request, reg *registry) (json.RawMessage, *jsonrpc2.Error) {
		p, rpcErr := unmarshalParams[T](req)
		if rpcErr != nil {
			return nil, rpcErr
		}
		res, err := fn(ctx, p, reg)
		if err != nil {
			return nil, err
		}

		raw, marshalErr := json.Marshal(res)
		if marshalErr != nil {
			return nil, &jsonrpc2.Error{Code: jsonrpc2.CodeInternalError, Message: marshalErr.Error()}
		}

		return raw, nil
	}
}

func (self *handlers) dispatch(ctx context.Context, req *jsonrpc2.Request, reg *registry) (json.RawMessage, *jsonrpc2.Error) {
	handler, ok := self.m[req.Method]
	if !ok {
		slog.Info("unknown method", "method", req.Method)
		return nil, &jsonrpc2.Error{Code: jsonrpc2.CodeMethodNotFound, Message: "unknown method: " + req.Method}
	}
	return handler(ctx, req, reg)
}

var validate = validator.New(validator.WithRequiredStructEnabled())

func unmarshalParams[T any](req *jsonrpc2.Request) (T, *jsonrpc2.Error) {
	var p T
	if req.Params != nil {
		if err := json.Unmarshal(*req.Params, &p); err != nil {
			return p, &jsonrpc2.Error{Code: jsonrpc2.CodeInvalidParams, Message: err.Error()}
		}
	}
	if err := validate.Struct(p); err != nil {
		return p, &jsonrpc2.Error{Code: jsonrpc2.CodeInvalidParams, Message: err.Error()}
	}
	return p, nil
}

func writeRPCResponse(w http.ResponseWriter, resp *jsonrpc2.Response) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		slog.Error("write jsonrpc response", "err", err)
	}
}
