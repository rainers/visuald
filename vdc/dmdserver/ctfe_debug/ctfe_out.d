// Fixture for the console-output scenario: exercises both pragma(msg) and
// __ctfeWrite, both of which write straight to the C streams rather than going
// through the compiler diagnostics callback.

module ctfe_out;

pragma(msg, "a pragma(msg) message");

int noisy(int n)
{
    __ctfeWrite("__ctfeWrite says hello\n");
    char[] buf;
    buf.length = 1;
    buf[0] = 'x';
    __ctfeWrite(buf);
    return n + 1;
}

enum int x = noisy(1);
enum int y = noisy(7);