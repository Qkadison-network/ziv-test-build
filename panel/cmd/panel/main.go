package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type User struct {
	ID       string `json:"id"`
	Password string `json:"password"`
	Quota    int64  `json:"quota"`
	Used     int64  `json:"used"`
	Enabled  bool   `json:"enabled"`
}

type Store struct {
	mu     sync.Mutex
	file   string
	byPass map[string]*User
}

type TrafficEntry struct {
	Tx uint64 `json:"tx"`
	Rx uint64 `json:"rx"`
}

type authRequest struct {
	Addr string `json:"addr"`
	Auth string `json:"auth"`
	Tx   uint64 `json:"tx"`
}

type authResponse struct {
	OK bool   `json:"ok"`
	ID string `json:"id"`
}

type userRequest struct {
	ID       string `json:"id"`
	Password string `json:"password"`
	Quota    string `json:"quota"`
	Enabled  *bool  `json:"enabled"`
}

var (
	listenAddr  string
	statsURL    string
	statsSecret string
	dataDir     string
	adminToken  string
	interval    int
)

func main() {
	flag.StringVar(&listenAddr, "listen", "127.0.0.1:8080", "panel HTTP listen address")
	flag.StringVar(&statsURL, "stats", "http://127.0.0.1:9999", "hysteria trafficStats base URL")
	flag.StringVar(&statsSecret, "stats-secret", "", "trafficStats secret")
	flag.StringVar(&dataDir, "data", "/etc/zivpn-compat", "data directory")
	flag.StringVar(&adminToken, "admin", "", "admin API token (generated if empty)")
	flag.IntVar(&interval, "interval", 5, "stats poll interval in seconds")
	flag.Parse()

	if err := os.MkdirAll(dataDir, 0755); err != nil {
		log.Fatalf("data dir: %v", err)
	}
	if adminToken == "" {
		adminToken = loadOrCreateToken(filepath.Join(dataDir, "token"))
	}
	st := &Store{file: filepath.Join(dataDir, "users.json"), byPass: map[string]*User{}}
	st.load()

	log.Printf("panel listening on %s (stats=%s, interval=%ds)", listenAddr, statsURL, interval)
	log.Printf("admin token: %s", adminToken)

	go st.pollLoop()

	mux := http.NewServeMux()
	mux.HandleFunc("/auth", st.handleAuth)
	mux.HandleFunc("/users", st.withAdmin(st.handleUsers))
	mux.HandleFunc("/users/reset", st.withAdmin(st.handleReset))
	mux.HandleFunc("/usage", st.withAdmin(st.handleUsage))
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "ok\n")
	})

	log.Fatal(http.ListenAndServe(listenAddr, mux))
}

func loadOrCreateToken(path string) string {
	if b, err := os.ReadFile(path); err == nil {
		if t := strings.TrimSpace(string(b)); t != "" {
			return t
		}
	}
	buf := make([]byte, 16)
	_, _ = rand.Read(buf)
	t := hex.EncodeToString(buf)
	_ = os.WriteFile(path, []byte(t+"\n"), 0600)
	return t
}

func (s *Store) load() {
	b, err := os.ReadFile(s.file)
	if err != nil {
		return
	}
	var users []*User
	if json.Unmarshal(b, &users) != nil {
		return
	}
	for _, u := range users {
		s.byPass[u.Password] = u
	}
}

func (s *Store) saveLocked() {
	users := make([]*User, 0, len(s.byPass))
	for _, u := range s.byPass {
		users = append(users, u)
	}
	b, _ := json.MarshalIndent(users, "", "  ")
	tmp := s.file + ".tmp"
	if os.WriteFile(tmp, b, 0600) == nil {
		_ = os.Rename(tmp, s.file)
	}
}

func (s *Store) findByID(id string) *User {
	for _, u := range s.byPass {
		if u.ID == id {
			return u
		}
	}
	return nil
}

func (s *Store) handleAuth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		_ = json.NewEncoder(w).Encode(authResponse{})
		return
	}
	var req authRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		_ = json.NewEncoder(w).Encode(authResponse{})
		return
	}
	s.mu.Lock()
	u := s.byPass[req.Auth]
	ok := u != nil && u.Enabled && (u.Quota == 0 || u.Used < u.Quota)
	var id string
	if ok {
		id = u.ID
	}
	s.mu.Unlock()
	_ = json.NewEncoder(w).Encode(authResponse{OK: ok, ID: id})
}

func (s *Store) withAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if tok != adminToken {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (s *Store) handleUsers(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.mu.Lock()
		users := make([]*User, 0, len(s.byPass))
		for _, u := range s.byPass {
			users = append(users, u)
		}
		s.mu.Unlock()
		writeJSON(w, users)
	case http.MethodPost:
		var req userRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if req.ID == "" || req.Password == "" {
			http.Error(w, "id and password required", http.StatusBadRequest)
			return
		}
		quota, err := parseSize(req.Quota)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		enabled := true
		if req.Enabled != nil {
			enabled = *req.Enabled
		}
		s.mu.Lock()
		for p, u := range s.byPass {
			if u.ID == req.ID && p != req.Password {
				delete(s.byPass, p)
			}
		}
		u := s.byPass[req.Password]
		if u == nil {
			u = &User{ID: req.ID, Password: req.Password}
			s.byPass[req.Password] = u
		}
		u.ID = req.ID
		u.Quota = quota
		u.Enabled = enabled
		s.saveLocked()
		s.mu.Unlock()
		writeJSON(w, u)
	case http.MethodDelete:
		id := r.URL.Query().Get("id")
		s.mu.Lock()
		for p, u := range s.byPass {
			if u.ID == id {
				delete(s.byPass, p)
			}
		}
		s.saveLocked()
		s.mu.Unlock()
		writeJSON(w, map[string]string{"deleted": id})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Store) handleReset(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	s.mu.Lock()
	for _, u := range s.byPass {
		if u.ID == id {
			u.Used = 0
			u.Enabled = true
		}
	}
	s.saveLocked()
	s.mu.Unlock()
	writeJSON(w, map[string]string{"reset": id})
}

func (s *Store) handleUsage(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	out := map[string]any{}
	for _, u := range s.byPass {
		out[u.ID] = map[string]any{"used": u.Used, "quota": u.Quota, "enabled": u.Enabled}
	}
	s.mu.Unlock()
	writeJSON(w, out)
}

func (s *Store) pollLoop() {
	for {
		s.poll()
		time.Sleep(time.Duration(interval) * time.Second)
	}
}

func (s *Store) poll() {
	req, err := http.NewRequest(http.MethodGet, statsURL+"/traffic?clear=1", nil)
	if err != nil {
		return
	}
	if statsSecret != "" {
		req.Header.Set("Authorization", statsSecret)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	var m map[string]TrafficEntry
	if json.NewDecoder(resp.Body).Decode(&m) != nil {
		return
	}
	s.mu.Lock()
	var kicked []string
	for id, e := range m {
		u := s.findByID(id)
		if u == nil {
			continue
		}
		u.Used += int64(e.Tx + e.Rx)
		if u.Quota > 0 && u.Used >= u.Quota && u.Enabled {
			u.Enabled = false
			kicked = append(kicked, id)
		}
	}
	s.saveLocked()
	s.mu.Unlock()
	if len(kicked) > 0 {
		kick(kicked)
	}
}

func kick(ids []string) {
	body, _ := json.Marshal(ids)
	req, err := http.NewRequest(http.MethodPost, statsURL+"/kick", strings.NewReader(string(body)))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	if statsSecret != "" {
		req.Header.Set("Authorization", statsSecret)
	}
	if resp, err := http.DefaultClient.Do(req); err == nil {
		resp.Body.Close()
	}
}

func parseSize(s string) (int64, error) {
	s = strings.TrimSpace(strings.ToUpper(s))
	if s == "" || s == "0" || s == "UNLIMITED" {
		return 0, nil
	}
	mult := int64(1)
	switch {
	case strings.HasSuffix(s, "TB"):
		mult = 1 << 40
		s = strings.TrimSpace(s[:len(s)-2])
	case strings.HasSuffix(s, "GB"):
		mult = 1 << 30
		s = strings.TrimSpace(s[:len(s)-2])
	case strings.HasSuffix(s, "MB"):
		mult = 1 << 20
		s = strings.TrimSpace(s[:len(s)-2])
	case strings.HasSuffix(s, "KB"):
		mult = 1 << 10
		s = strings.TrimSpace(s[:len(s)-2])
	case strings.HasSuffix(s, "B"):
		mult = 1
		s = strings.TrimSpace(s[:len(s)-1])
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || f < 0 {
		return 0, fmt.Errorf("invalid quota: %q", s)
	}
	return int64(f * float64(mult)), nil
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
