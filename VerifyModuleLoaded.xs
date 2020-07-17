#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>
#include <stdio.h>

Perl_ppaddr_t orig_subhandler;
Perl_ppaddr_t orig_reqhandler;

// If we do not use threads we will make this global
// The performance impact of fetching it each time is significant, so avoid it
// if we can.
#ifdef USE_ITHREADS
#define fetch_files \
    HV *files = get_hv("Test2::Plugin::VerifyModuleLoaded::FILES", GV_ADDMULTI)
#define fetch_loads \
    HV *loads = get_hv("Test2::Plugin::VerifyModuleLoaded::LOADS", GV_ADDMULTI)
#else
HV *files;
HV *loads;
#define fetch_files NOOP
#define fetch_loads NOOP
#endif

void _record_file(HV *dest, char *from_file, char *target_file) {
    long from_len = strlen(from_file);
    SV *from;
    SV **from_ptr = hv_fetch(dest, from_file, from_len, 0);
    if (from_ptr == NULL) {
        from = newRV_inc((SV*)newHV());
        hv_store(dest, from_file, from_len, from, 0);
    }
    else {
        from = *from_ptr;
    }

    hv_store((HV*)SvRV(from), target_file, strlen(target_file), &PL_sv_yes, 0);
}

char* _file_from_op(OP* op) {
    if (op != NULL && (op->op_type == OP_NEXTSTATE || op->op_type == OP_DBSTATE)) {
        return CopFILE(cCOPx(op));
    }

    return NULL;
}

static OP* my_subhandler(pTHX) {
    char *from_file = OutCopFILE(PL_curcop);

    OP* out = orig_subhandler(aTHX);

    const PERL_CONTEXT* cx = cxstack + cxstack_ix;
    if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
        GV * const cvgv = CvGV(cx->blk_sub.cv);

        if (isGV(cvgv)) {
            char *subname = GvNAME(cvgv);
            if(!strcmp(subname, "import"))  return out;
            if(!strcmp(subname, "END"))     return out;
            if(!strcmp(subname, "BEGIN"))   return out;
            if(!strcmp(subname, "DESTROY")) return out;
        }
    }

    char *target_file = _file_from_op(out);

    if (from_file != NULL && target_file != NULL) {
        fetch_files;
        _record_file(files, from_file, target_file);
    }

    return out;
}

static OP* my_reqhandler(pTHX) {
    dSP;
    SV **mark = PL_stack_base + TOPMARK;
    I32 items = (I32)(sp - mark);

    if (items >= 1) {
        char *target_file = savesvpv(TOPs);

        OP* out = orig_reqhandler(aTHX);

        char *from_file = _file_from_op(out);
        if (from_file != NULL && target_file != NULL) {
            fetch_loads;
            _record_file(loads, from_file, target_file);
        }

        return out;
    }

    return orig_reqhandler(aTHX);
}


MODULE = Test2::Plugin::VerifyModuleLoaded PACKAGE = Test2::Plugin::VerifyModuleLoaded

PROTOTYPES: ENABLE

BOOT:
    {
        //Initialize the global files HV, but only if we are not a threaded perl
#ifndef USE_ITHREADS
        files = get_hv("Test2::Plugin::VerifyModuleLoaded::FILES", GV_ADDMULTI);
        SvREFCNT_inc(files);
        loads = get_hv("Test2::Plugin::VerifyModuleLoaded::LOADS", GV_ADDMULTI);
        SvREFCNT_inc(loads);
#endif

        orig_subhandler = PL_ppaddr[OP_ENTERSUB];
        PL_ppaddr[OP_ENTERSUB] = my_subhandler;

        orig_reqhandler = PL_ppaddr[OP_REQUIRE];
        PL_ppaddr[OP_REQUIRE] = my_reqhandler;
    }
