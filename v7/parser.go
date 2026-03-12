package main

import (
	"bufio"
	"regexp"
	"strconv"
	"strings"
)

func ParseMakeMKVOutput(scanner *bufio.Scanner) DiscInfo {
	var info DiscInfo

	// Pre-Compile regex for speed
	reCInfo := regexp.MustCompile(`^CINFO:2,0,"(.*)"`)
	reTInfo := regexp.MustCompile(`^TINFO:(\d+),9,0,"(\d+):(\d+):(\d+)"`)
	reTSize := regexp.MustCompile(`^TINFO:(\d+),10,0,"(.*)"`)
	reFName := regexp.MustCompile(`^TINFO:(\d+),27,0,"(.*)"`)
	reSInfo := regexp.MustCompile(`^SINFO:(\d+),0,19,0,"(\d+)x(\d+)"`)

	resolutions := make(map[int]string)
	fileNames := make(map[int]string)
	fileSizes := make(map[int]string)

	for scanner.Scan() {
		line := scanner.Text()

		if m := reCInfo.FindStringSubmatch(line); m != nil {
			info.Title = strings.ReplaceAll(m[1], "_", " ")
		}

		if m := reFName.FindStringSubmatch(line); m != nil {
			idx, _ := strconv.Atoi(m[1])
			fileNames[idx] = m[2]
		}

		if m := reTSize.FindStringSubmatch(line); m != nil {
			idx, _ := strconv.Atoi(m[1])
			fileSizes[idx] = m[2]
		}

		if m := reTInfo.FindStringSubmatch(line); m != nil {
			idx, _ := strconv.Atoi(m[1])
			hrs, _ := strconv.Atoi(m[2])
			mins, _ := strconv.Atoi(m[3])

			title := TitleMetadata{
				Index:   idx,
				Minutes: (hrs * 60) + mins,
			}
			info.Features = append(info.Features, title)
		}

		if m := reSInfo.FindStringSubmatch(line); m != nil {
			idx, _ := strconv.Atoi(m[1])
			resolutions[idx] = m[2] + "x" + m[3]
		}
	}
	for i := range info.Features {
		info.Features[i].FileName = fileNames[info.Features[i].Index]
		info.Features[i].FileSize = fileSizes[info.Features[i].Index]
		info.Features[i].Resolution = resolutions[info.Features[i].Index]
	}
	return info
}
