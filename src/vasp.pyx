import numpy as np
from collections import Counter
# from lxml import etree
from xml.etree import cElementTree as etree


cdef extern from "fast_atoi.h":
    int fast_atoi(char *s)


cdef extern from "fast_atof.h":
    double fast_atof(char *s)


cdef double to_float(bytes s):
    return fast_atof(s) 


cdef int to_int(bytes s):
    return fast_atoi(s)


cdef long prod(long[:] mv):
    cdef int i, n
    cdef long res = 1
    n = mv.shape[0]
    for i in range(n):
        res *= mv[i]
    return res

to_type = {
    "string" : lambda x: x.strip() if x is not None else "",
    "int" : to_int,
    None: to_float,
    "": to_float,
    "logical": lambda x: x.strip() == "T"
}


def get_name(el):
    if el.tag in ["i", "v", "varray"]:
        return el.attrib.get("name", None)
    else:
        return el.tag + ("" if not "name" in el.attrib else ":" + el.attrib["name"])


def dummy(el, name):
    return {get_name(el): None}


def  parse_i(el, name):
    e_type = el.attrib.get("type", None)
    value = to_type[e_type](el.text)
    return {name: value}


def parse_v(el, name):
    e_type = el.attrib.get("type", None)
    value = [to_type[e_type](v_i) for v_i in el.text.split()]
    return {name: value}


def parse_varray(el, name):
    e_type = el.attrib.get("type", None)
    value = []
    for kid in el:
        if kid.tag == "v":
            parsed_kid = parse_v(kid, None)
            value.append(parsed_kid[None])
    return {name: value}


def parse_array(el, name):
    # array has dimensions, field names and sets of values
    dims = []
    fields = []
    vals = []
    for kid in el:
        if kid.tag == "dimension":
            dims.append(kid.text)
        if kid.tag == "field":
            fields.append({"name": kid.text, "type": kid.attrib.get("type", None)})
        if kid.tag == "set":
            is_float_set = all([f["type"] is None for f in fields])
            if not is_float_set:
                types = [to_type[f["type"]] for f in fields]
                ifields = range(len(fields))
                vals = parse_general_set(kid, types, ifields)
            else:
                nfields = len(fields)
                # get set dimensions
                set_dims = get_set_dimension(kid)
                set_dims.append(nfields)
                # allocate memory: make one long 1-d array
                vals = np.zeros(set_dims, dtype=float).reshape(-1)
                parse_float_set(kid, vals, np.array(set_dims, dtype=int))
                # reshape values back to their original dimensions
                vals = vals.reshape(set_dims)
    return {name: {"dimensions": dims, "fields": fields, "values": vals}}


def get_set_dimension(el, acc=None):
    """Get dimensions of a float set"""
    if acc is None:
        acc = []
    if len(el) > 0:
        acc.append(len(el))
        get_set_dimension(el[0], acc)
    return acc


cdef void parse_float_set(el, double[:] value, long[:] set_dims, int cur=0):
    cdef:
        int i, i_kid, nelem
    for i_kid in range(set_dims[0]):
        kid = el[i_kid]
        if kid.tag == "set":   # another set dimension
            new_dims = set_dims[1:]
            nelem = prod(new_dims)
            parse_float_set(kid, value, new_dims, cur+i_kid*nelem)
        elif kid.tag == "r":    # just row
            kid_values = kid.text.split()
            for i in range(set_dims[-1]):
                value[cur+i] = to_float(kid_values[i])
            cur += set_dims[-1]


def parse_general_set(el, types, ifields):
    value = []
    for kid in el:
        # split by columns
        value.append([types[i](kid[i].text) for i in ifields])
    return value


def parse_time(el, name):
    value = [float(t) for t in [el.text[:8], el.text[8:]]]
    return {name: value}


def parse_entry(e_type):
    def _parse(el, name):
        return {name: to_type[e_type](el.text)}
    return _parse


base_cases = {
    "i": parse_i,
    "v": parse_v,
    "varray": parse_varray,
    "array": parse_array,
    "time": parse_time,
    "atoms": parse_entry("int"),
    "types": parse_entry("int"),
}


def parse_etree(dom):
    d = {}
    # get our name
    name = get_name(dom)
    # check for base cases
    parsed = base_cases.get(dom.tag, lambda _, __: None)(dom, name)
    if parsed is not None:
        # we are in base case
        d.update(parsed)
        return d
    # the rules here are simple: 
    # 1. update d with all the node attributes (except for name)
    for k, v in dom.attrib.items():
        if k != "name": 
            d[k] = v  # TODO: d[dom.nodeName] should be updated

    # 2. then check all child element nodes
    children = [el for el in dom]
    kid_names = [get_name(kid) for kid in children]
    # 3. if some of the names are identical, put parsed data in a list (eg, scstep)
    count_kids = Counter(kid_names)
    d[name] = {kid_name: [] if count_kids[kid_name] > 1 else {} for kid_name in count_kids}

    for (kid_name, kid) in zip(kid_names, children):
        if count_kids[kid_name] > 1:
            d[name][kid_name].append(parse_etree(kid)[kid_name])
        else:
            # 4. if not, put them in a dict
            d[name].update(parse_etree(kid))
    return d


def parse_file(f_name):
    tree = etree.parse(f_name)
    return parse_etree(tree.getroot())