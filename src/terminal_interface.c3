module terminal_interface::ti;
import libc;
import std::io;
import std::collections::list;
import std::thread;
import std::net::os;

macro char @ctrl_key(char key)
{
  return key.to_upper() - 64;
}

macro @escape_sequence(String $seq)
{
  return "\u001b" +++ $seq;
}

const TIOCGWINSZ = 0x5413;
const TIOCSWINSZ = 0x5414;

struct Winsize {
  ushort ws_row;
  ushort ws_col;
  ushort ws_xpixel;   /* unused */
  ushort ws_ypixel;   /* unused */
}

extern fn CInt ioctl(CInt fd, CInt op, ...);

struct TerminalInterface @private {
  bool initialized;
  bool running;
  Termios original_termios;
  Termios termios;
  File *input_file;
  File *output_file;
  Fd input_fd;
  Winsize winsize;
  bool pending_resize;
  List(<String>) input_queue;
}

Mutex queue_mutex;
Thread input_thread;

TerminalInterface current_ti @private;

const O_NONBLOCK = 0x800;

fn int read_input(void*)
{
  int flags = os::fcntl((NativeSocket)current_ti.input_fd, os::F_GETFL, 0);
  os::fcntl((NativeSocket)current_ti.input_fd, os::F_SETFL, flags | O_NONBLOCK);

  while OUTER: (current_ti.initialized) {
    char *buf = mem::temp_new_array(char, 3);
    usz len = 0;
    usz wanted_len = 1;

    while(len < wanted_len) {
      char! ch = current_ti.input_file.read_byte();

      if (!current_ti.initialized) break OUTER;

      if (catch excuse = ch) {
        if (excuse == IoError.EOF) {
          thread::sleep_ms(50);
          continue;
        } else {
          return 1;
        }
      }

      if (ch > 0) {
        buf[len++] = ch;
        // Handle multibytes
        if (len == 1 && buf[0] == 27) wanted_len = 3;
      }
    }

    queue_mutex.lock()!!;
    current_ti.input_queue.push((String)buf[0:len]);
    queue_mutex.unlock()!!;
  }

  return 0;
}

// @TODO: Keybind struct & handling

fn void update_winsize()
{
  assert(current_ti.initialized, "You need to call init first");
  ioctl(current_ti.input_fd, TIOCGWINSZ, &current_ti.winsize);
  current_ti.pending_resize = true;
}

fault TIError
{
  ALREADY_INITIALIZED
}

fn void! init(File* new_input_file = io::stdin(), File* new_output_file = io::stdout())
{
  if (current_ti.initialized) return TIError.ALREADY_INITIALIZED?;

  current_ti.initialized = true;

  current_ti.input_file = new_input_file;
  current_ti.output_file = new_output_file;

  current_ti.input_fd = libc::fileno(current_ti.input_file.file);

  current_ti.original_termios.getAttr(current_ti.input_fd);
  current_ti.termios = current_ti.original_termios;

  current_ti.input_queue.temp_init();

  queue_mutex.init()!;

  update_winsize();
}

fn void winch_handler(int) {
  update_winsize();
}

fn void! start()
{
  assert(current_ti.initialized, "You need to call init first");
  assert(!current_ti.running, "TI is already running");
	write(
    // Switch to alternate screen
    @escape_sequence("[?1049h") +++
    // Reset colors
    @escape_sequence("[0m") +++
    // Go to first line & column
    @escape_sequence("[H")
  )!;

  // Disable Canonical mode for raw input processing and priting the keypresses
  current_ti.termios.c_lflag &= ~(termios::ICANON | termios::ECHO);
  // Disable signals, so Ctrl + c doesn't kill the app.
  current_ti.termios.c_lflag &= ~(termios::ISIG);
  // Disable flow, so Ctrl + q & Ctrl + s
  current_ti.termios.c_iflag &= ~(termios::IXON);
  current_ti.termios.setAttr(current_ti.input_fd, termios::TCSANOW);

  flush()!;

  Sigaction sa;
  sa.sa_handler = &winch_handler;
  sa.sa_flags = libc::SA_RESTART;
  current_ti.running = true;
  libc::sigaction(0x1c, &sa, null);

  input_thread.create(&read_input, null)!;
}

fn void! close()
{
  assert(current_ti.initialized, "You need to call init first");
  // Exit alternate screen and reset colors
	write(@escape_sequence("[?1049l") +++ @escape_sequence("[0m"))!;
  flush()!;
  // Reset termios
  current_ti.original_termios.setAttr(current_ti.input_fd, termios::TCSANOW);

  current_ti.initialized = false;
  current_ti.running = false;

  input_thread.detach()!;
}

fn void stop()
{
  current_ti.running = false;
}

fn bool is_running()
{
  return current_ti.running;
}

enum EventType {
  INPUT,
  WIN_RESIZE,
}

struct Event {
  EventType type;
  union {
    String input;
    Winsize new_size;
  }
}

fault EventFaults {
  EVENT_QUEUE_EMPTY,
}

fn Event! get_event() {
  assert(current_ti.initialized, "You need to call init first");

  if (current_ti.pending_resize) {
    current_ti.pending_resize = false;
    return {
      .type = EventType.WIN_RESIZE,
      .new_size = get_winsize(),
    };
  }

  String input = get_input();

  if (input != "") return {
    .type = EventType.INPUT,
    .input = input,
  };

  thread::sleep_ms(50);

  return EventFaults.EVENT_QUEUE_EMPTY?;
}

fn Winsize get_winsize()
{
  assert(current_ti.initialized, "You need to call init first");
  return current_ti.winsize;
}

fn String get_input()
{
  assert(current_ti.initialized, "You need to call init first");

  String! input = current_ti.input_queue.pop();

  if (catch excuse = input) {
    return "";
  }

  return input;
}

fn void! set_line_col(usz line, usz col, String content)
{
  writefn(@escape_sequence("[%d;%df%s"), line, col, content)!;
}

fn void! set_line(usz line, String content)
{
  set_line_col(line, 0, content)!;
}

fn void! flush()
{
  assert(current_ti.initialized, "You need to call init first");
  current_ti.output_file.flush()!;
}

fn void! write_char(char c)
{
  assert(current_ti.initialized, "You need to call init first");
  current_ti.output_file.write_byte(c)!;
}

fn void! append_char(void* data, char c)
{
  assert(current_ti.initialized, "You need to call init first");
  current_ti.output_file.write_byte(c)!;
}

fn void! write(String content)
{
  assert(current_ti.initialized, "You need to call init first");
  current_ti.output_file.write(content)!;
}

fn void! writen(String content)
{
  write(content)!;
  write_char('\n')!;
}

fn usz! writef(String format, args...)
{
  assert(current_ti.initialized, "You need to call init first");
  Formatter formatter;
	formatter.init(&append_char);
	return formatter.vprintf(format, args);
}

fn usz! writefn(String format, args...)
{
  usz! result = writef(format, ...args);
  write_char('\n')!;

  return result;
}

fn void! clear(bool should_flush = true)
{
  write(@escape_sequence("[2J"))!;
  if (should_flush)
  {
    flush()!;
  }
}

fn void! clear_line(bool should_flush = true)
{
  write(@escape_sequence("[2K"))!;
  if (should_flush)
  {
    flush()!;
  }
}

fn void! clear_line_from_cursor(bool should_flush = true)
{
  write(@escape_sequence("[0K"))!;
  if (should_flush)
  {
    flush()!;
  }
}

fn void! set_cursor_pos(usz line, usz col)
{
  writef(@escape_sequence("[%d;%dH"), line, col)!;
  flush()!;
}

fn void! reset_style(bool should_flush = true)
{
  write(@escape_sequence("[0m"))!;
  if (should_flush)
  {
    flush()!;
  }
}

def TermString = DString;

enum SimpleColor: short (String value) {
  BLACK = "30",
  BG_BLACK = "40",
  RED = "31",
  BG_RED = "41",
  GREEN = "32",
  BG_GREEN = "42",
  YELLOW = "33",
  BG_YELLOW = "43",
  BLUE = "34",
  BG_BLUE = "44",
  MAGENTA = "35",
  BG_MAGENTA = "45",
  CYAN = "36",
  BG_CYAN = "46",
  WHITE = "37",
  BG_WHITE = "47",
  DEFAULT = "39",
  BG_DEFAULT = "49",
  RESET = "0",
  BG_RESET = "0",
}

enum Style: short (String value) {
  CLEAR = "0",
  BOLD = "1",
  RESET_BOLD = "21",
  DIM = "2",
  RESET_DIM = "22",
  ITALIC = "3",
  RESET_ITALIC = "23",
  UNDERLINE = "4",
  RESET_UNDERLINE = "24",
  BLINKING = "5",
  RESET_BLINKING = "25",
  INVERSE = "7",
  RESET_INVERSE = "27",
  HIDDEN = "8",
  RESET_HIDDEN = "28",
  STRIKE_THROUGH = "9",
  RESET_STRIKE_THROUGH = "29",
}

fn TermString* TermString.style(&self, Style style)
{
  self.append_chars(ti::@escape_sequence("["));
  self.append_chars(style.value);
  self.append_chars("m");

  return self;
}

fn TermString* TermString.reset_style(&self)
{
  return self.style(CLEAR);
}

fn TermString* TermString.color_simple(&self, SimpleColor color)
{
  self.append_chars(ti::@escape_sequence("["));
  self.append_chars(color.value);
  self.append_chars("m");

  return self;
}

<*
  @require color < 256 : "Color must be less than 256"
*>
fn TermString* TermString.color_256(&self, ushort color, bool background = false)
{
  self.append_chars(ti::@escape_sequence("["));
  if (!background) {
    self.append_chars("38;5;");
  } else {
    self.append_chars("48;5;");
  }
  self.appendf("%d", color);
  self.append_chars("m");

  return self;
}
