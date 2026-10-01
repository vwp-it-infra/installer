package envtimeout

import (
	"os"
	"testing"
	"time"
)

func TestDuration(t *testing.T) {
	const envKey = "OPENSHIFT_INSTALL_TEST_TIMEOUT"

	tests := []struct {
		name       string
		envValue   string
		setEnv     bool
		defaultVal time.Duration
		want       time.Duration
	}{
		{name: "unset", setEnv: false, defaultVal: 15 * time.Minute, want: 15 * time.Minute},
		{name: "empty", setEnv: true, envValue: "", defaultVal: 15 * time.Minute, want: 15 * time.Minute},
		{name: "valid", setEnv: true, envValue: "45m", defaultVal: 15 * time.Minute, want: 45 * time.Minute},
		{name: "invalid string", setEnv: true, envValue: "not-a-duration", defaultVal: 15 * time.Minute, want: 15 * time.Minute},
		{name: "zero", setEnv: true, envValue: "0", defaultVal: 15 * time.Minute, want: 15 * time.Minute},
		{name: "negative", setEnv: true, envValue: "-5m", defaultVal: 15 * time.Minute, want: 15 * time.Minute},
		{name: "above cap", setEnv: true, envValue: "4h", defaultVal: 15 * time.Minute, want: 15 * time.Minute},
		{name: "at cap", setEnv: true, envValue: "3h", defaultVal: 15 * time.Minute, want: 3 * time.Hour},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Cleanup(func() { os.Unsetenv(envKey) })
			if tt.setEnv {
				t.Setenv(envKey, tt.envValue)
			} else {
				os.Unsetenv(envKey)
			}
			if got := Duration(envKey, tt.defaultVal); got != tt.want {
				t.Fatalf("Duration() = %v, want %v", got, tt.want)
			}
		})
	}
}
