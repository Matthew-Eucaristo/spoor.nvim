// Package server is the shop HTTP API.
package server

import (
	"encoding/json"
	"net/http"

	"example.com/shop/internal/config"
	"example.com/shop/internal/order"
)

// Server serves the shop's HTTP API.
type Server struct {
	cfg  config.Config
	repo order.Repo
	mux  *http.ServeMux
}

// New wires a server to its configuration and order store.
func New(cfg config.Config, repo order.Repo) *Server {
	s := &Server{cfg: cfg, repo: repo, mux: http.NewServeMux()}
	s.mux.HandleFunc("/orders", s.handleOrders)
	s.mux.HandleFunc("/health", handleHealth)
	return s
}

// Run starts listening.
func (s *Server) Run() error {
	return http.ListenAndServe(s.cfg.Addr, s.mux)
}

func (s *Server) handleOrders(w http.ResponseWriter, r *http.Request) {
	var o order.Order
	if err := json.NewDecoder(r.Body).Decode(&o); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := order.Process(r.Context(), s.repo, o, s.cfg.Discount); err != nil {
		http.Error(w, err.Error(), http.StatusUnprocessableEntity)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}
