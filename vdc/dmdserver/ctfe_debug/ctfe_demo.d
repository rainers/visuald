module ctfe_demo;

int fact(int n)
{
	int r = 1;
	int i = 2;
	while (i <= n)
	{
		r = r * i;
		i = i + 1;
	}
	return r;
}

int addup(int n)
{
	int sum = 0;
	for (int k = 1; k <= n; k++)
		sum += fact(k);
	return sum;
}

enum int f6 = fact(6);
enum int total = addup(3);
