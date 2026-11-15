// A value of a class is a reference to an instance: the fields of the instance
// expand under it, those of its base classes first, and the same for the class
// references held by other values and for the `this` of a member function.
module ctfe_class;

class Shape
{
	int sides;
	string name;
	int twice()
	{
		return sides * 2; // BP_METHOD
	}
}

class Triangle : Shape
{
	double perimeter;
}

class Named
{
	string label;
	Shape shape;
}

struct Holder
{
	Named owner;
	int count;
}

int sidesOf(Shape s)
{
	return s.sides; // BP_ARG
}

Holder make()
{
	Triangle t = new Triangle;
	t.sides = 3;
	t.name = "tri";
	t.perimeter = 7.5;

	Named nm = new Named;
	nm.label = "holder";
	nm.shape = t;

	Shape none;
	Holder h;
	h.owner = nm;
	h.count = 2;

	int n = sidesOf(t) + t.twice(); // BP_LOCAL
	return h;
}

enum auto holder = make();
