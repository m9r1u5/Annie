"""Province list shared by the map, routing and search builders.
id, name, bbox (west, south, east, north) - a little wider than each province."""

PROVINCES = [
    ("gauteng", "Gauteng", [27.10, -26.95, 29.10, -25.05]),
    ("western-cape", "Western Cape", [17.70, -34.90, 24.30, -30.90]),
    ("eastern-cape", "Eastern Cape", [22.50, -34.30, 30.30, -30.00]),
    ("kwazulu-natal", "KwaZulu-Natal", [28.80, -31.20, 33.00, -26.70]),
    ("free-state", "Free State", [24.30, -30.80, 29.90, -26.55]),
    ("north-west", "North West", [22.60, -28.00, 28.40, -24.60]),
    ("mpumalanga", "Mpumalanga", [28.10, -27.90, 32.10, -24.00]),
    ("limpopo", "Limpopo", [26.30, -25.50, 31.95, -22.10]),
    ("northern-cape", "Northern Cape", [16.40, -32.90, 25.60, -24.70]),
]


def overlaps(a, b):
    """True if two west,south,east,north boxes touch."""
    return a[0] <= b[2] and b[0] <= a[2] and a[1] <= b[3] and b[1] <= a[3]
