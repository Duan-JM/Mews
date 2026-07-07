package ipc

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"sync"
	"time"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/store"
)

var ErrUnavailable = errors.New("mews agent is not running")

type request struct {
	Type  string       `json:"type"`
	Event events.Event `json:"event,omitempty"`
}

type response struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

func Serve(socketPath, eventPath string) error {
	if err := removeStaleSocket(socketPath); err != nil {
		return err
	}

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	defer os.Remove(socketPath)
	defer listener.Close()

	done := make(chan struct{})
	var stopOnce sync.Once
	for {
		conn, err := listener.Accept()
		if err != nil {
			select {
			case <-done:
				return nil
			default:
				return err
			}
		}

		go handleConnection(conn, eventPath, func() {
			stopOnce.Do(func() {
				close(done)
				listener.Close()
			})
		})
	}
}

func Ping(socketPath string) error {
	return send(socketPath, request{Type: "ping"})
}

func Stop(socketPath string) error {
	return send(socketPath, request{Type: "stop"})
}

func SendEvent(socketPath string, event events.Event) error {
	return send(socketPath, request{Type: "event", Event: event})
}

func handleConnection(conn net.Conn, eventPath string, stop func()) {
	defer conn.Close()

	var req request
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		writeResponse(conn, response{OK: false, Error: err.Error()})
		return
	}

	switch req.Type {
	case "ping":
		writeResponse(conn, response{OK: true})
	case "stop":
		writeResponse(conn, response{OK: true})
		stop()
	case "event":
		if err := store.AppendEvent(eventPath, req.Event); err != nil {
			writeResponse(conn, response{OK: false, Error: err.Error()})
			return
		}
		writeResponse(conn, response{OK: true})
	default:
		writeResponse(conn, response{OK: false, Error: "unknown request type"})
	}
}

func send(socketPath string, req request) error {
	conn, err := net.DialTimeout("unix", socketPath, 500*time.Millisecond)
	if err != nil {
		return ErrUnavailable
	}
	defer conn.Close()

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return err
	}

	var resp response
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return err
	}
	if !resp.OK {
		return errors.New(resp.Error)
	}
	return nil
}

func removeStaleSocket(socketPath string) error {
	if info, err := os.Stat(socketPath); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return errors.New("socket path exists but is not a socket")
		}
		conn, err := net.DialTimeout("unix", socketPath, 100*time.Millisecond)
		if err == nil {
			conn.Close()
			return errors.New("socket is already active")
		}
		return os.Remove(socketPath)
	} else if !os.IsNotExist(err) {
		return err
	}
	return nil
}

func writeResponse(conn net.Conn, resp response) {
	_ = json.NewEncoder(conn).Encode(resp)
}
