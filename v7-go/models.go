package main

import "math"

type TitleMetadata struct {
	Index      int
	Minutes    int
	Resolution string
	Width      int
	Height     int
	FileName   string
	FileSize   string
}

type MatchResult struct {
	Index       int
	Title       string
	Year        string
	ImdbID      string
	Method      string
	NeedsReview bool
}

type DiscInfo struct {
	Title        string
	Features     []TitleMetadata
	Extras       []TitleMetadata
	DistinctCuts []TitleMetadata
	Matches      []MatchResult
}

type DriveInfo struct {
	Index   int
	State   uint32
	FsFlags uint32
	Label   string
	Device  string
}

// GroupByMinutes - PS1= [math]::Abs($_.Minutes - $feature.Minutes) -le 5
func IsDuplicate(m1, m2 int, threshold int) bool {
	return math.Abs(float64(m1-m2)) <= float64(threshold)
}
