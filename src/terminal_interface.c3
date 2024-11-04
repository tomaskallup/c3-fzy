module terminal_interface::ti;
import libc;
import std::io;

const EB = "\u001b";

macro char @ctrl_key(char key)
{
  return key.to_upper() - 64;
}

macro @escape_sequence(String $seq)
{
  return "\u001b" +++ $seq;
}

// @TODO: Add macros for colors etc.

struct TerminalInterface {
  Termios original_termios;
  Termios termios;
  File *input_file;
  File *output_file;
  Fd fd;
}

// @TODO: Add set_style method
// @TODO: Add reset_style method
// @TODO: Keybind struct & handling

fn void TerminalInterface.init(&self)
{
  // Default to stdin
  if (self.input_file == null) self.input_file = io::stdin();
  // Default to stdout
  if (self.output_file == null) self.output_file = io::stdout();

  if (!self.fd) self.fd = libc::fileno(self.input_file.file);

  self.original_termios.getAttr(self.fd);
  self.termios = self.original_termios;
}

fn void! TerminalInterface.start(&self)
{
	self.write(
    // Switch to alternate screen
    @escape_sequence("[?1049h") +++
    // Reset colors
    @escape_sequence("[0m") +++
    // Go to first line & column
    @escape_sequence("[H")
  )!;

  // Disable Canonical mode for raw input processing and priting the keypresses
  self.termios.c_lflag &= (Tcflags)~(termios::ICANON | termios::ECHO);
  // Disable signals, so Ctrl + c doesn't kill the app.
  self.termios.c_lflag &= (Tcflags)~(termios::ISIG);
  // Disable flow, so Ctrl + q & Ctrl + s
  // self.termios.c_iflag &= ~(termios::IXON);
  self.termios.setAttr(self.fd, (int)termios::TCSANOW);

  self.flush()!;
}

fn void! TerminalInterface.close(&self)
{
  // Exit alternate screen and reset colors
	self.write(@escape_sequence("[?1049l") +++ @escape_sequence("[0m"))!;
  self.flush()!;
  // Reset termios
  self.original_termios.setAttr(self.fd, (int)termios::TCSANOW);
}

fn void! TerminalInterface.set_line_col(&self, usz line, usz col, String content)
{
  self.writefn(@escape_sequence("[%d;%dH%s"), line, col, content)!;
}

fn void! TerminalInterface.set_line(&self, usz line, String content)
{
  self.set_line_col(line, 0, content)!;
}

fn void! TerminalInterface.flush(&self)
{
  self.output_file.flush()!;
}

fn void! TerminalInterface.write_char(&self, char c)
{
  self.output_file.write_byte(c)!;
}

fn void! TerminalInterface.write(&self, String content)
{
  self.output_file.write(content)!;
}

fn void! TerminalInterface.writen(&self, String content)
{
  self.output_file.write(content)!;
  self.write_char('\n')!;
}

fn usz! TerminalInterface.writef(&self, String format, args...)
{
  Formatter formatter;
	formatter.init((OutputFn)&TerminalInterface.write_char, self);
	return formatter.vprintf(format, args);
}

fn usz! TerminalInterface.writefn(&self, String format, args...)
{
  usz! result = self.writef(format, ...args);
  self.write_char('\n')!;

  return result;
}

fn void! TerminalInterface.clear(&self, bool flush = true)
{
  self.write(@escape_sequence("[2J"))!;
  if (flush)
  {
    self.flush()!;
  }
}

fn void! TerminalInterface.clear_line(&self, bool flush = true)
{
  self.write(@escape_sequence("[2K"))!;
  if (flush)
  {
    self.flush()!;
  }
}

fn void! TerminalInterface.clear_line_from_cursor(&self, bool flush = true)
{
  self.write(@escape_sequence("[0K"))!;
  if (flush)
  {
    self.flush()!;
  }
}

fn void! TerminalInterface.set_cursor_pos(&self, usz line, usz col)
{
  self.writef(@escape_sequence("[%d;%dH"), line, col)!;
  self.flush()!;
}
