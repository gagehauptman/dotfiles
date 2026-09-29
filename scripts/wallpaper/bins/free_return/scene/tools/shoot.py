#!/usr/bin/env python3
"""Finds the free return's TLI (angle on the parking orbit, speed) for
../src/cr3bp.rs: the same CR3BP, step size and RK4, then damped Newton on
both for a 250 km perilune and a return perigee at the Earth's surface.
Prints TLI_ANGLE and TLI_SPEED to paste into cr3bp.rs.

Pure Python, a few minutes: python3 tools/shoot.py
"""
import math, sys
MU = 0.012150585
L = 384400.0
RE, RM = 6378.137 / L, 1737.4 / L
R0 = (6378.137 + 185.0) / L

def acc(x, y, vx, vy):
    dx1, dx2 = x + MU, x - 1 + MU
    r1 = (dx1 * dx1 + y * y) ** 1.5
    r2 = (dx2 * dx2 + y * y) ** 1.5
    ax = 2 * vy + x - (1 - MU) * dx1 / r1 - MU * dx2 / r2
    ay = -2 * vx + y - (1 - MU) * y / r1 - MU * y / r2
    return ax, ay

def step_size(x, y):
    r1 = math.hypot(x + MU, y); r2 = math.hypot(x - 1 + MU, y)
    return min(0.004, 0.01 * min(r1, 4 * r2) ** 1.5)

def rk4(s, h):
    x, y, vx, vy = s
    def f(x, y, vx, vy):
        ax, ay = acc(x, y, vx, vy); return vx, vy, ax, ay
    k1 = f(x, y, vx, vy)
    k2 = f(x + h/2*k1[0], y + h/2*k1[1], vx + h/2*k1[2], vy + h/2*k1[3])
    k3 = f(x + h/2*k2[0], y + h/2*k2[1], vx + h/2*k2[2], vy + h/2*k2[3])
    k4 = f(x + h*k3[0], y + h*k3[1], vx + h*k3[2], vy + h*k3[3])
    return (x + h/6*(k1[0]+2*k2[0]+2*k3[0]+k4[0]), y + h/6*(k1[1]+2*k2[1]+2*k3[1]+k4[1]),
            vx + h/6*(k1[2]+2*k2[2]+2*k3[2]+k4[2]), vy + h/6*(k1[3]+2*k2[3]+2*k3[3]+k4[3]))

def start(theta, v):
    # prograde circular-ish LEO + TLI, inertial speed v, rotating-frame velocity
    x = -MU + R0 * math.cos(theta); y = R0 * math.sin(theta)
    tx, ty = -math.sin(theta), math.cos(theta)
    return (x, y, v * tx + y, v * ty - x)

def fly(theta, v, tmax=2.0, record=False):
    s = start(theta, v); t = 0.0
    peri_m = 9; left = False; pts = [(t, s)] if record else None
    peri_e = 9
    while t < tmax:
        h = step_size(s[0], s[1]); s = rk4(s, h); t += h
        if record: pts.append((t, s))
        r1 = math.hypot(s[0] + MU, s[1]); r2 = math.hypot(s[0] - 1 + MU, s[1])
        peri_m = min(peri_m, r2)
        if r1 > 0.5: left = True
        if left and peri_m < 0.1 and r2 > 0.3:
            peri_e = min(peri_e, r1)
            if r1 < RE: break
            if r1 > peri_e + 1e-6 and peri_e < 0.2: break
    return peri_m, peri_e, t, pts


def main():
    tgt = (RM + 250 / L, RE + 50 / L)
    # From a scan over the angle at 10.7 (~10.96 km/s).
    th, v = math.radians(228), 10.7

    def f(th, v):
        pm, pe, _, _ = fly(th, v, 2.5)
        return pm - tgt[0], pe - tgt[1]

    for _ in range(40):
        r = f(th, v)
        if abs(r[0] * L) < 0.5 and abs(r[1] * L) < 0.5:
            break
        d = 1e-6
        a, b = f(th + d, v), f(th, v + d)
        j = [[(a[0] - r[0]) / d, (b[0] - r[0]) / d], [(a[1] - r[1]) / d, (b[1] - r[1]) / d]]
        det = j[0][0] * j[1][1] - j[0][1] * j[1][0]
        dth = -(j[1][1] * r[0] - j[0][1] * r[1]) / det
        dv = -(-j[1][0] * r[0] + j[0][0] * r[1]) / det
        # Damped: the flyby is sensitive and full steps overshoot.
        k = min(1.0, 0.008 / max(abs(dth), 1e-12), 0.004 / max(abs(dv), 1e-12))
        th, v = th + k * dth, v + k * dv
    pm, pe, t, _ = fly(th, v, 2.5)
    print("perilune %.1f km, perigee %.1f km, %.2f days" % ((pm - RM) * L, (pe - RE) * L, t * 375196 / 86400))
    print("const TLI_ANGLE: f64 = %r;" % (th % (2 * math.pi)))
    print("const TLI_SPEED: f64 = %r;" % v)


if __name__ == "__main__":
    main()
