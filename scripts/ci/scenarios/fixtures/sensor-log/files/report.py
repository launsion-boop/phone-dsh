# SPDX-License-Identifier: MIT
"""Sensor summaries."""


def to_fahrenheit(c):
    return c * 5 / 9 + 32


def summary(rows):
    temps = [row["temp"] for row in rows]
    hums = [row["hum"] for row in rows]
    return {
        "temp_min": min(temps),
        "temp_max": max(temps),
        "temp_avg": sum(temps) / len(temps),
        "hum_min": min(hums),
        "hum_max": max(hums),
        "hum_avg": sum(hums) / len(hums),
    }
