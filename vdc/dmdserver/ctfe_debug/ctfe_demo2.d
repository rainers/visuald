module ctfe_demo2;

struct Pt { int x; int y; }

int inner(int k)
{
	int m = k * 2;
	int q = m + 1;
	return q;
}

int outer(int n)
{
	int t = 0;
	foreach (i; 0 .. n)
		t += inner(i);
	return t;
}

enum int total = outer(2);
