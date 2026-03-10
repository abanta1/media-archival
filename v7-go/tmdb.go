package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
)

type TMDBResult struct {
	ID          int    `json:"id"`
	Title       string `json:"title"`
	ReleaseDate string `json:"release_date"`
	Runtime     int    `json:"runtime"`
	Overview    string `json:"overview"`
	ImdbID      string `json:"imdb_id"`
}

type TMDBResponse struct {
	Results []TMDBResult `json:"results"`
}

func SearchMovieMatch(title string, runtime int, apiKey string) (*TMDBResult, string) {
	encodedTitle := url.QueryEscape(title)
	searchURL := fmt.Sprintf("https://api.themoviedb.org/3/search/movie?api_key=%s&query=%s", apiKey, encodedTitle)
	debugLog("TMDB search URL: %s", searchURL)

	resp, err := http.Get(searchURL)
	if err != nil {
		return nil, "Connection Error"
	}
	defer resp.Body.Close()

	var searchResp TMDBResponse
	json.NewDecoder(resp.Body).Decode(&searchResp)
	debugLog("TMDB search results: %d", len(searchResp.Results))

	if len(searchResp.Results) == 0 {
		return nil, "No Match"
	}

	// Check top 5 results for runtime match
	for _, movie := range searchResp.Results[:min(5, len(searchResp.Results))] {
		// Get full details for runtime
		detailsURL := fmt.Sprintf("https://api.themoviedb.org/3/movie/%d?api_key=%s", movie.ID, apiKey)
		debugLog("Fetching details for '%s' (id=%d), runtime=%d", movie.Title, movie.ID, runtime)

		dResp, _ := http.Get(detailsURL)
		var details TMDBResult
		json.NewDecoder(dResp.Body).Decode(&details)
		dResp.Body.Close()

		diff := mathAbs(runtime - details.Runtime)
		debugLog("  '%s' runtime=%d diff=%d", details.Title, details.Runtime, diff)

		if diff <= 2 {
			return &details, "Runtime Match"
		}
		if diff <= 10 {
			return &details, "Runtime within 10m"
		}
	}

	return &searchResp.Results[0], "Popularity Fallback"
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
func mathAbs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}
