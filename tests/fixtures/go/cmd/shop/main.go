// Command shop serves the orders API.
package main

import (
	"log"

	"example.com/shop/internal/config"
	"example.com/shop/internal/server"
	"example.com/shop/internal/store"
)

func main() {
	cfg := config.Load()
	srv := server.New(cfg, store.NewMemory())
	if err := srv.Run(); err != nil {
		log.Fatal(err)
	}
}
