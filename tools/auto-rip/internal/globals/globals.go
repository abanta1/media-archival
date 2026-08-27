// Copyright (c) 2000-2026 Anthony Banta - MIT License
package globals

var DebugMode bool
var LogLevel int

const (
	// Reset ANSI to normal
	RESET = "\033[0m"

	// Styles
	BOLD      = "\033[1m"
	UNDERLINE = "\033[4m"
	BOLDUNDER = "\033[1;4m"

	// Specific combos
	EMERG    = ""
	ALERT    = ""
	CRITICAL = "\033[1;4;37;41m"
	ERROR    = "\033[1;31m"
	WARN     = "\033[33m"
	NOTICE   = ""
	INFO     = ""
	DEBUG    = "\033[33;40m"

	// Standard Colors
	FGBLACK   = "\033[30m"
	FGRED     = "\033[31m"
	FGGREEN   = "\033[32m"
	FGYELLOW  = "\033[33m"
	FGBLUE    = "\033[34m"
	FGMAGENTA = "\033[35m"
	FGCYAN    = "\033[36m"
	FGWHITE   = "\033[37m"

	BGBLACK   = "\033[40m"
	BGRED     = "\033[41m"
	BGGREEN   = "\033[42m"
	BGYELLOW  = "\033[43m"
	BGBLUE    = "\033[44m"
	BGMAGENTA = "\033[45m"
	BGCYAN    = "\033[46m"
	BGWHITE   = "\033[47m"

	// Special
	BELL      = "\a"
	BACKSPACE = "\b"
	TAB       = "\t"
	CR        = "\r"
	LF        = "\n"
)

