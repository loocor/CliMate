package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/viper"
)

type Config struct {
	CodexBin   string `mapstructure:"codex_bin"`
	BindIP     string `mapstructure:"bind_ip"`
	Port       int    `mapstructure:"port"`
	TSAuthKey  string `mapstructure:"ts_auth_key"`
	TSHostname string `mapstructure:"ts_hostname"`
	TSStateDir string `mapstructure:"ts_state_dir"`
}

type Result struct {
	Config     Config
	ConfigFile string
}

func Load(args []string) (Result, error) {
	configPath := configPathFromArgs(args)
	if configPath == "" {
		configPath = defaultConfigPath()
	}

	v := viper.New()
	var configFile string
	if configPath != "" {
		v.SetConfigFile(configPath)
		if err := v.ReadInConfig(); err != nil {
			return Result{}, fmt.Errorf("read config: %w", err)
		}
		configFile = v.ConfigFileUsed()
	}

	var cfg Config
	if err := v.Unmarshal(&cfg); err != nil {
		return Result{}, fmt.Errorf("unmarshal config: %w", err)
	}

	return Result{Config: cfg, ConfigFile: configFile}, nil
}

func configPathFromArgs(args []string) string {
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--config" || arg == "-config" {
			if i+1 < len(args) {
				return args[i+1]
			}
			return ""
		}
		if strings.HasPrefix(arg, "--config=") {
			return strings.TrimPrefix(arg, "--config=")
		}
		if strings.HasPrefix(arg, "-config=") {
			return strings.TrimPrefix(arg, "-config=")
		}
	}
	return ""
}

func defaultConfigPath() string {
	candidates := []string{
		filepath.Join("config", "config.yaml"),
		filepath.Join("config", "config.yml"),
		filepath.Join("server", "config", "config.yaml"),
		filepath.Join("server", "config", "config.yml"),
	}
	for _, path := range candidates {
		if fileExists(path) {
			return path
		}
	}
	return ""
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !info.IsDir()
}
