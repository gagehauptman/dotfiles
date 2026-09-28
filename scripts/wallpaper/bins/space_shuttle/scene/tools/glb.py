"""Minimal GLB reader: world-space triangles per primitive (numpy, DracoPy)."""
import json, struct
import numpy as np


def _quat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def _local(n):
    if 'matrix' in n:
        return np.array(n['matrix'], float).reshape(4, 4).T
    m = np.eye(4)
    m[:3, :3] = _quat(n.get('rotation', [0, 0, 0, 1])) * np.array(n.get('scale', [1, 1, 1]))
    m[:3, 3] = n.get('translation', [0, 0, 0])
    return m


def load(path):
    """-> (gltf json, [(name, world positions (n,3), triangles (m,3))])"""
    b = open(path, 'rb').read()
    assert b[:4] == b'glTF'
    off, gj, bin_ = 12, None, None
    while off < len(b):
        ln, ty = struct.unpack_from('<II', b, off)
        off += 8
        chunk = b[off:off + ln]
        off += ln
        if ty == 0x4E4F534A:
            gj = json.loads(chunk)
        elif ty == 0x004E4942:
            bin_ = chunk

    def view(i):
        bv = gj['bufferViews'][i]
        o = bv.get('byteOffset', 0)
        return bin_[o:o + bv['byteLength']], bv.get('byteStride', 0)

    def acc(i):
        a = gj['accessors'][i]
        comp = np.dtype({5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a['componentType']])
        nc = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[a['type']]
        data, stride = view(a['bufferView'])
        start = a.get('byteOffset', 0)
        stride = stride or comp.itemsize * nc
        rows = [np.frombuffer(data, comp, nc, start + k * stride) for k in range(a['count'])]
        return np.array(rows)

    prims = []

    def walk(ni, parent):
        n = gj['nodes'][ni]
        m = parent @ _local(n)
        if 'mesh' in n:
            mesh = gj['meshes'][n['mesh']]
            for p in mesh['primitives']:
                if p.get('mode', 4) != 4:
                    continue
                dr = p.get('extensions', {}).get('KHR_draco_mesh_compression')
                if dr:
                    import DracoPy
                    dm = DracoPy.decode(view(dr['bufferView'])[0])
                    pos = np.asarray(dm.points, float).reshape(-1, 3)
                    idx = np.asarray(dm.faces, np.int64).reshape(-1, 3)
                else:
                    pos = acc(p['attributes']['POSITION']).astype(float)
                    idx = (acc(p['indices']).reshape(-1, 3) if 'indices' in p
                           else np.arange(len(pos)).reshape(-1, 3)).astype(np.int64)
                prims.append((n.get('name') or mesh.get('name', '?'), pos @ m[:3, :3].T + m[:3, 3], idx))
        for c in n.get('children', []):
            walk(c, m)

    for r in gj['scenes'][gj.get('scene', 0)]['nodes']:
        walk(r, np.eye(4))
    return gj, prims
