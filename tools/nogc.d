module nogc;

extern (C)
{
    void _d_register_manual_gc();

    // replace during link to not use the conservative GC, so no memory freed automatically
    void* register_default_gcs()
    {
        pragma(inline, false);
        // do not call, they register implicitly through pragma(crt_constructor)
        // avoid being optimized away
        auto reg2 = &_d_register_manual_gc;
        return reg2;
    }
}
