package main

import (
	"sort"
)

func ProcessCuts(info *DiscInfo) {
	if len(info.Features) == 0 {
		return
	}

	// 1. Sort all titles by Minutes Descedning
	sort.Slice(info.Features, func(i, j int) bool {
		return info.Features[i].Minutes > info.Features[j].Minutes
	})

	maxMinutes := info.Features[0].Minutes
	variance := 20
	dupThreshold := 5

	var mainFeatures []TitleMetadata
	var extras []TitleMetadata

	// 2. Separate Main Features from Extras
	for _, t := range info.Features {
		if (maxMinutes - t.Minutes) <= variance {
			mainFeatures = append(mainFeatures, t)
		} else {
			extras = append(extras, t)
		}
	}

	// 3. Identify Distinct Cuts (Theatrical vs Extended)
	// Use map to track which indices already 'grouped'
	assigned := make(map[int]bool)
	var distinct []TitleMetadata

	for _, f := range mainFeatures {
		if assigned[f.Index] {
			continue
		}

		// Find others within the 5-min dup threshold
		for _, other := range mainFeatures {
			if !assigned[other.Index] && IsDuplicate(f.Minutes, other.Minutes, dupThreshold) {
				assigned[other.Index] = true
			}
		}
		distinct = append(distinct, f)
	}

	// Sort distinct cuts by duration asc
	sort.Slice(distinct, func(i, j int) bool {
		return distinct[i].Minutes < distinct[j].Minutes
	})

	info.Features = mainFeatures
	info.Extras = extras
	info.DistinctCuts = distinct
}
