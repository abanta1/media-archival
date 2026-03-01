function Convert-AudioCodecName {
    param([string]$codec)

    if (-not $codec) { return "unknown" }
    
    $newCodec = switch -Regex ($codec.ToLower()) {
        '(?i)mp3'                   {  "mp3" }
        '(?i)aac'                   {  "aac" }
        '(?i)ac3|ac-3|a_ac3'        {  "ac3" }
        '(?i)eac3'                  {  "eac3" }
        '(?i)truehd|true-hd'        {  "truehd" }
        '(?i)flac'                  {  "flac" }
        '(?i)lpcm'                  {  "lpcm" }
        '(?i)pcm_s16le'             {  "pcm_s16le" }
        '(?i)pcm_s24le'             {  "pcm_s24le" }
        default                     {  $codec.ToLower() }
    }

    return $newCodec
}

function Convert-ChannelCount {
    param([double]$channels)

    $newChannel = switch ($channels) {
        {$_ -ge 7.1}  { "7.1"; break }
        {$_ -ge 5.1}  { "5.1"; break }
        {$_ -ge 2.0}  { "2.0"; break }
        {$_ -ge 1.0}  { "1.0"; break }
        default        { "0" }
    }

    return $newChannel
}

function Convert-IsoCode {
    param([string]$isoText)

    if (-not $isoText) { return "und" }

    switch ($isoText.ToLower()) {
        "en"    { "eng"; break }
        "eng"   { "eng"; break }
        "fr"    { "fra"; break }
        "fre"   { "fra"; break }
        "fra"   { "fra"; break }
        "es"    { "spa"; break }
        "spa"   { "spa"; break }
        "it"    { "ita"; break }
        "ita"   { "ita"; break }
        "de"    { "deu"; break }
        "deu"   { "deu"; break }
        "ru"    { "rus"; break }
        "rus"   { "rus"; break }
        "ja"    { "jpn"; break }
        "ko"    { "kor"; break }
        "zh"    { "chi"; break }
        "pt"    { "por"; break }
        default { if ($isoText.Length -eq 3) { $isoText } else { "und" } }
    }
}

function Convert-IsoToLanguage {
    param([string]$isoCode)

    if (-not $isoCode) { return "Unknown" }

    $newLanguage = switch ($isoCode.ToLower()) {
        "eng"   { "English" }
        "fra"   { "French" }
        "spa"   { "Spanish" }
        "ita"   { "Italian" }
        "deu"   { "German" }
        "rus"   { "Russian" }
        "jpn"   { "Japanese" }
        "kor"   { "Korean" } 
        "chi"   { "Chinese" } 
        "por"   { "Portuguese" }
        default { "Unknown" }
    }

    return $newLanguage
}

function Convert-SubCodecType {
    param([string]$codec)

    if (-not $codec) { return "unknown" }
    
    $newCodec = switch -Regex ($codec.ToLower()) {
        '(?i)vobsub'                {  "bitmap"; break }
        '(?i)pgs'                   {  "bitmap"; break }
        '(?i)hdmv_pgs_subtitle'     {  "bitmap"; break }
        '(?i)bitmap'                {  "bitmap"; break }
        '(?i)dvd_subtitle'          {  "bitmap"; break }

        '(?i)subrip|srt'            {  "text"; break }
        '(?i)ass'                   {  "text"; break }
        '(?i)ssa'                   {  "text"; break }
        '(?i)text'                  {  "text"; break }
        '(?i)utf'                   {  "text"; break }
        default                     {  "unknown" }
    }

    return $newCodec
}

Export-ModuleMember -Function Convert-AudioCodecName, Convert-ChannelCount, Convert-IsoCode, Convert-IsoToLanguage, Convert-SubCodecType