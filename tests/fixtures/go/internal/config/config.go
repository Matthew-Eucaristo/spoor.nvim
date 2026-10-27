// Package config reads the shop settings.
package config

import "os"

// Config holds the settings the shop reads at startup.
type Config struct {
	Addr     string
	Discount int
}

// Load reads the configuration from the environment.
func Load() Config {
	return Config{Addr: env("SHOP_ADDR", ":8080"), Discount: 10}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
