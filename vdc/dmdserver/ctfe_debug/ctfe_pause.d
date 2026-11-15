module ctfe_pause;

long slow(int n)
{
	long s = 0;
	for (int i = 0; i < n; i++)
		foreach (int j; 0 .. 10)
			s += i * j;
	return s;
}

enum long v = slow(30000);
