module ctfe_err;

int f(int n)
{
	return 1 / n;
}

enum int bad = f(0);
